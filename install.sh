#!/usr/bin/env bash
# pulse-agent 一键安装 / 卸载脚本
#
#   curl -fsSL https://raw.githubusercontent.com/gokele/pulse-agnes/main/install.sh \
#     | sudo bash -s -- --server <面板地址> --id <节点ID> --token <该节点的密钥>
#
#   curl -fsSL https://raw.githubusercontent.com/gokele/pulse-agnes/main/install.sh \
#     | sudo bash -s -- --uninstall
#
# 重复执行即为升级：换掉二进制并重启服务，节点 ID 与密钥照旧。
#
# 二进制与校验和都从 Agent 的发布仓库取，面板只负责接收上报，不分发任何文件。
# Agent 与服务端各自发版，所以这里是 pulse-agnes 而不是 pulse-releases。
set -euo pipefail

REPO="${PULSE_REPO:-gokele/pulse-agnes}"
RELEASE="${PULSE_RELEASE:-latest}"
SERVER="${PULSE_SERVER:-}"
TOKEN="${PULSE_TOKEN:-}"
NODE_ID="${PULSE_NODE_ID:-}"
NODE_NAME="${PULSE_NODE_NAME:-}"
BINARY_URL=""
INSECURE="${PULSE_INSECURE:-0}"
ACTION="install"

INSTALL_DIR="/opt/pulse-agent"
CONF_DIR="/etc/pulse-agent"
SERVICE="pulse-agent"

usage() {
  cat <<USAGE
用法：curl -fsSL <脚本地址> | sudo bash -s -- --server URL --id ID --token TOKEN

参数：
  --server URL      面板地址（必填），如 https://pulse.example.com
  --token TOKEN     该节点的密钥（必填），在后台「安装命令」里复制
  --id ID           节点 ID，默认主机名
  --name NAME       节点显示名，默认同 ID
  --release TAG     指定版本，默认 latest
  --repo OWNER/NAME Agent 发布仓库，默认 ${REPO}
  --binary-url URL  直接指定二进制地址（跳过 GitHub 查询与校验和比对）
  --insecure        跳过 TLS 证书校验
  --uninstall       卸载
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
    --server) need_value "$@"; SERVER="$2"; shift 2 ;;
    --token) need_value "$@"; TOKEN="$2"; shift 2 ;;
    --id) need_value "$@"; NODE_ID="$2"; shift 2 ;;
    --name) need_value "$@"; NODE_NAME="$2"; shift 2 ;;
    --release) need_value "$@"; RELEASE="$2"; shift 2 ;;
    --repo) need_value "$@"; REPO="$2"; shift 2 ;;
    --binary-url) need_value "$@"; BINARY_URL="$2"; shift 2 ;;
    --insecure) INSECURE=1; shift ;;
    --uninstall) ACTION="uninstall"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 2 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行（sudo）" >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "当前系统没有 systemd，请手动运行 pulse-agent" >&2
  exit 1
fi

if [ "$ACTION" = "uninstall" ]; then
  systemctl stop "$SERVICE" 2>/dev/null || true
  systemctl disable "$SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE}.service"
  rm -rf "$INSTALL_DIR" "$CONF_DIR"
  systemctl daemon-reload
  echo "pulse-agent 已卸载"
  exit 0
fi

[ -n "$NODE_ID" ] || NODE_ID="$(hostname -s 2>/dev/null || hostname || true)"
if [ -z "$TOKEN" ] || [ -z "$NODE_ID" ]; then
  echo "缺少 --id 或 --token，请从后台的「安装命令」复制完整命令" >&2
  exit 2
fi
if [ -z "$SERVER" ]; then
  echo "缺少 --server，请填面板地址，如 --server https://pulse.example.com" >&2
  exit 2
fi
SERVER="${SERVER%/}"
[ -n "$NODE_NAME" ] || NODE_NAME="$NODE_ID"

# 这些值要写进 systemd 的 EnvironmentFile，混入换行会被当成新的环境变量
for pair in "TOKEN:$TOKEN" "NODE_ID:$NODE_ID" "NODE_NAME:$NODE_NAME" "SERVER:$SERVER"; do
  name="${pair%%:*}"; value="${pair#*:}"
  case "$value" in
    *[$'\n\r']*) echo "${name} 里不能包含换行" >&2; exit 2 ;;
  esac
done

case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  armv7l|armv7) ARCH="armv7" ;;
  *) echo "不支持的架构: $(uname -m)" >&2; exit 1 ;;
esac
ASSET="pulse-agent-linux-${ARCH}"

CURL_OPTS=(-fsSL --retry 3 --connect-timeout 15)
[ "$INSECURE" = "1" ] && CURL_OPTS+=(-k)

mkdir -p "$INSTALL_DIR" "$CONF_DIR"
TMP="$(mktemp)"
SUMS="$(mktemp)"
trap 'rm -f "$TMP" "$SUMS"' EXIT

# --- 解析下载地址 ---------------------------------------------------------
# 不带 --binary-url 时走 GitHub Release，并强制校验 SHA-256。
if [ -n "$BINARY_URL" ]; then
  echo "下载 ${BINARY_URL}（已指定直链，跳过校验和比对）"
  if ! curl "${CURL_OPTS[@]}" -o "$TMP" "$BINARY_URL"; then
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
  if ! curl "${CURL_OPTS[@]}" -o "$TMP" "${BASE}/${ASSET}"; then
    echo "下载失败：${BASE}/${ASSET}" >&2
    echo "请确认这台机器能访问 GitHub；若网络受限，可用 --binary-url 指定一个可达的镜像地址" >&2
    exit 1
  fi
  if ! curl "${CURL_OPTS[@]}" -o "$SUMS" "${BASE}/checksums.txt"; then
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
  echo "下载到的文件是空的" >&2
  exit 1
fi

install -m 0755 "$TMP" "${INSTALL_DIR}/pulse-agent"

cat > "${CONF_DIR}/agent.env" <<ENV
PULSE_SERVER=${SERVER}
PULSE_TOKEN=${TOKEN}
PULSE_NODE_ID=${NODE_ID}
PULSE_NODE_NAME=${NODE_NAME}
PULSE_INSECURE=${INSECURE}
ENV
chmod 0600 "${CONF_DIR}/agent.env"

if ! id -u pulse-agent >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin pulse-agent 2>/dev/null || true
fi
if ! id -u pulse-agent >/dev/null 2>&1; then
  echo "无法创建 pulse-agent 用户，请先手动创建后重试" >&2
  exit 1
fi

# 自动更新需要 Agent 能在自己的目录里写临时文件并改名覆盖旧二进制。
# 改名要的是目录写权限，所以把目录（连同二进制）交给服务账号。
# 代价：Agent 一旦被攻破，就能改写自己的二进制获得持久化。
# 不想要这个能力的话，删掉下面两行并去掉 unit 里的 ReadWritePaths。
chown -R pulse-agent:pulse-agent "$INSTALL_DIR" 2>/dev/null || chown -R pulse-agent "$INSTALL_DIR" 2>/dev/null || true
chmod 0755 "$INSTALL_DIR"

cat > "/etc/systemd/system/${SERVICE}.service" <<UNIT
[Unit]
Description=pulse-agent (极简探针)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=pulse-agent
EnvironmentFile=${CONF_DIR}/agent.env
ExecStart=${INSTALL_DIR}/pulse-agent
Restart=always
RestartSec=5
# ICMP 只需要 CAP_NET_RAW，不用 root
AmbientCapabilities=CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_RAW
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadOnlyPaths=/
# 自动更新时 Agent 要替换 ${INSTALL_DIR}/pulse-agent，这个目录必须可写
ReadWritePaths=${INSTALL_DIR}

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null 2>&1 || true
# 必须是 restart 而不是 enable --now：重复执行脚本就是「升级」，
# 服务已经在跑的话 --now 什么都不做，新二进制躺在磁盘上、跑的还是旧进程。
systemctl restart "$SERVICE"
sleep 1
if systemctl is-active --quiet "$SERVICE"; then
  echo "pulse-agent 已启动：节点 ${NODE_ID}（${NODE_NAME}） → ${SERVER}"
  echo "查看日志：journalctl -u ${SERVICE} -f"
else
  echo "pulse-agent 启动失败，查看：journalctl -u ${SERVICE} -n 50" >&2
  exit 1
fi
