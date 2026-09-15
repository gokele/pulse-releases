#!/usr/bin/env bash
# pulse-server 安装 / 升级脚本（systemd）
#
# 在线安装（推荐）：
#   curl -fsSL https://raw.githubusercontent.com/gokele/pulse-releases/main/install-server.sh \
#     | sudo bash -s -- --port 8899
#
# 离线安装：把发布包解压后在目录里执行
#   sudo ./install-server.sh
#   脚本会优先使用同目录下的 pulse-server，不再访问网络。
#
# 重复执行即为升级：二进制换掉、配置与数据保留。
set -euo pipefail

REPO="${PULSE_REPO:-gokele/pulse-releases}"
RELEASE="${PULSE_RELEASE:-latest}"
PORT="${PULSE_PORT:-8899}"
BINARY_URL=""

INSTALL_DIR="/opt/pulse"
DATA_DIR="/var/lib/pulse"
CONF_DIR="/etc/pulse"
SERVICE="pulse-server"

usage() {
  cat <<USAGE
用法：sudo ./install-server.sh [选项]
      curl -fsSL <脚本地址> | sudo bash -s -- [选项]

选项：
  --port PORT       监听端口，默认 ${PORT}
  --release TAG     指定版本，默认 latest（仅在线安装时有效）
  --repo OWNER/NAME 发布仓库，默认 ${REPO}
  --binary-url URL  直接指定二进制地址（跳过校验和比对）
USAGE
}

need_value() {
  if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
    echo "选项 $1 缺少取值" >&2
    exit 2
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --port) need_value "$@"; PORT="$2"; shift 2 ;;
    --release) need_value "$@"; RELEASE="$2"; shift 2 ;;
    --repo) need_value "$@"; REPO="$2"; shift 2 ;;
    --binary-url) need_value "$@"; BINARY_URL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 2 ;;
  esac
done

case "$PORT" in
  ''|*[!0-9]*) echo "端口必须是数字：$PORT" >&2; exit 2 ;;
esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "端口超出范围：$PORT" >&2
  exit 2
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行（sudo）" >&2
  exit 1
fi
if ! command -v systemctl >/dev/null 2>&1; then
  echo "当前系统没有 systemd，无法按服务安装" >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "不支持的架构: $(uname -m)（服务端只发布 amd64 / arm64）" >&2; exit 1 ;;
esac
ASSET="pulse-server-linux-${ARCH}"

# 管道执行时 $0 是 bash，取不到脚本所在目录，此时只能走在线安装。
HERE=""
if [ -f "${BASH_SOURCE[0]:-}" ]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

TMP="$(mktemp)"
SUMS="$(mktemp)"
trap 'rm -f "$TMP" "$SUMS"' EXIT

# --- 取得二进制 -----------------------------------------------------------
if [ -n "$HERE" ] && [ -f "$HERE/pulse-server" ]; then
  echo "使用本地二进制 $HERE/pulse-server"
  cp "$HERE/pulse-server" "$TMP"
elif [ -n "$BINARY_URL" ]; then
  echo "下载 ${BINARY_URL}（已指定直链，跳过校验和比对）"
  if ! curl -fsSL --retry 3 --connect-timeout 15 -o "$TMP" "$BINARY_URL"; then
    echo "下载失败：${BINARY_URL}" >&2
    exit 1
  fi
else
  if [ "$RELEASE" = "latest" ]; then
    BASE="https://github.com/${REPO}/releases/latest/download"
  else
    BASE="https://github.com/${REPO}/releases/download/${RELEASE}"
  fi
  echo "下载 ${BASE}/${ASSET}"
  if ! curl -fsSL --retry 3 --connect-timeout 15 -o "$TMP" "${BASE}/${ASSET}"; then
    echo "下载失败：${BASE}/${ASSET}" >&2
    echo "请确认这台机器能访问 GitHub；也可以下载发布包后离线安装" >&2
    exit 1
  fi
  if ! curl -fsSL --retry 3 --connect-timeout 15 -o "$SUMS" "${BASE}/checksums.txt"; then
    echo "下载 checksums.txt 失败，无法校验二进制，已放弃安装" >&2
    exit 1
  fi
  WANT="$(awk -v f="$ASSET" '$2 == f || $2 == "*" f { print $1; exit }' "$SUMS")"
  if [ -z "$WANT" ]; then
    echo "checksums.txt 里没有 ${ASSET} 的校验和，已放弃安装" >&2
    exit 1
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    GOT="$(sha256sum "$TMP" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    GOT="$(shasum -a 256 "$TMP" | awk '{print $1}')"
  else
    echo "系统里没有 sha256sum / shasum，无法校验，已放弃安装" >&2
    exit 1
  fi
  if [ "$GOT" != "$WANT" ]; then
    echo "校验和不匹配，已丢弃下载内容" >&2
    echo "  期望 ${WANT}" >&2
    echo "  实际 ${GOT}" >&2
    exit 1
  fi
  echo "校验和通过 (${GOT:0:16}…)"
fi

if [ ! -s "$TMP" ]; then
  echo "拿到的二进制是空文件" >&2
  exit 1
fi

# --- 安装 -----------------------------------------------------------------
id -u pulse >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin pulse
if ! id -u pulse >/dev/null 2>&1; then
  echo "无法创建 pulse 用户，请先手动创建后重试" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR" "$DATA_DIR" "$CONF_DIR"
FIRST_RUN=0
[ -f "$DATA_DIR/pulse.db" ] || FIRST_RUN=1

install -m 0755 "$TMP" "$INSTALL_DIR/pulse-server"
chown -R pulse:pulse "$DATA_DIR"
# 后台的「更新服务端」要在 /opt/pulse 里写临时文件并改名覆盖旧二进制，
# 改名要的是目录写权限，所以把目录连同二进制交给服务账号。
# 不需要就地升级的话，删掉下面这行并去掉 unit 里的 ReadWritePaths=/opt/pulse。
chown -R pulse:pulse "$INSTALL_DIR"

# 端口等参数写进独立的 env 文件：升级会覆盖 unit，写在这里才不会丢
if [ -f "$CONF_DIR/server.env" ]; then
  sed -i "s|^PULSE_LISTEN=.*|PULSE_LISTEN=:${PORT}|" "$CONF_DIR/server.env"
else
  printf 'PULSE_LISTEN=:%s\n' "$PORT" > "$CONF_DIR/server.env"
fi
chmod 0644 "$CONF_DIR/server.env"

cat > "/etc/systemd/system/${SERVICE}.service" <<UNIT
[Unit]
Description=Pulse server (极简探针面板)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=pulse
Group=pulse
WorkingDirectory=${INSTALL_DIR}
# 端口等参数放在 ${CONF_DIR}/server.env 里，改完 systemctl restart ${SERVICE} 即可，
# 不用动这个单元文件（升级时它会被覆盖）。
EnvironmentFile=-${CONF_DIR}/server.env
Environment=PULSE_LISTEN=:${PORT}
ExecStart=${INSTALL_DIR}/pulse-server -data ${DATA_DIR}
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${DATA_DIR}
# 后台的「更新服务端」要替换 ${INSTALL_DIR}/pulse-server，该目录必须可写
ReadWritePaths=${INSTALL_DIR}
# 面板只需要读写数据目录和监听端口，其余能力一律收掉
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectClock=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null 2>&1 || true
systemctl restart "$SERVICE"
sleep 2

if ! systemctl is-active --quiet "$SERVICE"; then
  echo "pulse-server 启动失败，查看：journalctl -u ${SERVICE} -n 50" >&2
  exit 1
fi

echo
if [ "$FIRST_RUN" = "1" ]; then
  journalctl -u "$SERVICE" --no-pager -n 30 2>/dev/null | grep -E '初始管理员账号|初始管理员密码|登录后台' || true
  echo
fi
echo "面板：http://<本机IP>:${PORT}      后台：http://<本机IP>:${PORT}/admin"
echo "日志：journalctl -u ${SERVICE} -f"
echo "改端口：编辑 ${CONF_DIR}/server.env 里的 PULSE_LISTEN，然后 systemctl restart ${SERVICE}"
echo "忘记密码：systemctl stop ${SERVICE} && sudo -u pulse ${INSTALL_DIR}/pulse-server reset-password -data ${DATA_DIR} && systemctl start ${SERVICE}"
