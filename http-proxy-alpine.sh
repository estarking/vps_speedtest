
#!/bin/sh
set -eu

# Alpine Linux Tinyproxy 一键安装脚本
# 适用于单实例、轻量级 NAT VPS

CONF="/etc/tinyproxy/tinyproxy.conf"
LOGDIR="/var/log/tinyproxy"

if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用 root 用户运行。"
    exit 1
fi

if [ ! -f /etc/alpine-release ]; then
    echo "错误：本脚本仅支持 Alpine Linux。"
    exit 1
fi

echo "=================================="
echo "    Tinyproxy 一键安装配置"
echo "=================================="

# 安装软件包
echo "[1/5] 安装 Tinyproxy..."
apk add tinyproxy tinyproxy-openrc

if ! id tinyproxy >/dev/null 2>&1; then
    echo "错误：未找到 tinyproxy 用户。"
    exit 1
fi

# 输入配置
printf "监听端口 [20027]: "
read -r PORT
PORT="${PORT:-20027}"

case "$PORT" in
    ''|*[!0-9]*)
        echo "错误：端口必须是数字。"
        exit 1
        ;;
esac

if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "错误：端口范围为 1-65535。"
    exit 1
fi

printf "用户名 [gentle]: "
read -r USERNAME
USERNAME="${USERNAME:-gentle}"

case "$USERNAME" in
    ''|*[!a-zA-Z0-9._-]*)
        echo "错误：用户名只允许字母、数字、点、下划线和连字符。"
        exit 1
        ;;
esac

while :; do
    printf "请输入密码（至少12位，不显示）: "
    stty -echo
    if ! read -r PASSWORD; then
        stty echo
        printf "\n"
        exit 1
    fi
    stty echo
    printf "\n"

    case "$PASSWORD" in
        ''|*[!a-zA-Z0-9._-]*)
            echo "密码只允许字母、数字、点、下划线和连字符。"
            continue
            ;;
    esac

    if [ "${#PASSWORD}" -lt 12 ]; then
        echo "密码至少需要12位。"
        continue
    fi

    printf "请再次输入密码确认: "
    stty -echo
    if ! read -r PASSWORD2; then
        stty echo
        printf "\n"
        exit 1
    fi
    stty echo
    printf "\n"

    if [ "$PASSWORD" != "$PASSWORD2" ]; then
        echo "两次密码不一致，请重新输入。"
        continue
    fi
    break
done

# 备份旧配置
echo "[2/5] 生成配置..."
mkdir -p /etc/tinyproxy "$LOGDIR"

if [ -f "$CONF" ]; then
    cp -p "$CONF" "${CONF}.bak.$(date +%Y%m%d%H%M%S)"
    echo "旧配置已备份。"
fi

cat > "$CONF" <<EOF
User tinyproxy
Group tinyproxy

Port $PORT
Timeout 120
MaxClients 10

BasicAuth $USERNAME $PASSWORD

ConnectPort 443
EOF

chown root:tinyproxy "$CONF"
chmod 640 "$CONF"
chown tinyproxy:tinyproxy "$LOGDIR"
chmod 750 "$LOGDIR"

unset PASSWORD PASSWORD2

# 清理 OpenRC 旧状态
echo "[3/5] 整理服务状态..."
rc-service tinyproxy stop >/dev/null 2>&1 || true

# 本脚本用于单个 Tinyproxy 实例
if command -v killall >/dev/null 2>&1; then
    killall tinyproxy 2>/dev/null || true
fi

sleep 1

if pgrep -x tinyproxy >/dev/null 2>&1; then
    echo "错误：仍有 Tinyproxy 进程运行，请检查后重试。"
    exit 1
fi

rm -f /run/tinyproxy.pid /var/run/tinyproxy.pid
rc-service tinyproxy zap >/dev/null 2>&1 || true
rc-update add tinyproxy default

# 启动服务
echo "[4/5] 启动 Tinyproxy..."
if ! rc-service tinyproxy start; then
    echo "错误：启动失败，日志如下："
    tail -n 40 "$LOGDIR/tinyproxy.log" 2>/dev/null || true
    exit 1
fi

sleep 1

if ! rc-service tinyproxy status; then
    echo "错误：服务状态异常，日志如下："
    tail -n 40 "$LOGDIR/tinyproxy.log" 2>/dev/null || true
    exit 1
fi

# 检查监听端口
echo "[5/5] 检查监听..."
if ! netstat -lnt 2>/dev/null | grep -F ":${PORT} " >/dev/null; then
    echo "错误：端口 $PORT 未监听。"
    tail -n 40 "$LOGDIR/tinyproxy.log" 2>/dev/null || true
    exit 1
fi

echo
echo "=================================="
echo "       安装配置完成"
echo "=================================="
echo "代理类型：HTTP"
echo "内部监听端口：$PORT"
echo "用户名：$USERNAME"
echo "开机自启：已配置"
echo "密码：已设置（未显示）"
echo
echo "注意：请确认 NAT 公网端口映射到内部端口 $PORT。"
echo
echo "查看状态：rc-service tinyproxy status"
echo "重启服务：rc-service tinyproxy restart"
echo "停止服务：rc-service tinyproxy stop"
echo "=================================="
