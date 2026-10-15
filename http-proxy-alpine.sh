#!/bin/sh
set -eu

if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 运行此脚本"
    exit 1
fi

if [ ! -f /etc/alpine-release ]; then
    echo "此脚本仅适用于 Alpine Linux"
    exit 1
fi

echo "===== 安装 Tinyproxy ====="
apk add tinyproxy tinyproxy-openrc

CONF=/etc/tinyproxy/tinyproxy.conf

if [ ! -f "$CONF" ]; then
    echo "未找到配置文件：$CONF"
    exit 1
fi

printf "代理监听端口 [20027]: "
read -r PORT
PORT=${PORT:-20027}

case "$PORT" in
    ''|*[!0-9]*)
        echo "端口必须是数字"
        exit 1
        ;;
esac

if [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then
    echo "请输入 1024 到 65535 之间的端口"
    exit 1
fi

printf "代理用户名 [gentle]: "
read -r USERNAME
USERNAME=${USERNAME:-gentle}

case "$USERNAME" in
    ''|*[!A-Za-z0-9._-]*)
        echo "用户名只允许字母、数字、点、下划线和连字符"
        exit 1
        ;;
esac

while :; do
    printf "请输入新的代理密码（不显示输入内容）: "
    read -r -s PASSWORD
    printf "\n"

    case "$PASSWORD" in
        ''|*[!A-Za-z0-9._-]*)
            echo "密码不能为空，只允许字母、数字、点、下划线和连字符"
            continue
            ;;
    esac

    if [ "${#PASSWORD}" -lt 12 ]; then
        echo "密码至少需要 12 个字符"
        continue
    fi

    break
done

# 备份原配置
cp -p "$CONF" "$CONF.bak.$(date +%Y%m%d%H%M%S)"

# 删除相关的有效旧配置，保留其余默认设置
sed -i -E \
    '/^[[:space:]]*(Port|Listen|Timeout|MaxClients|MinSpareServers|MaxSpareServers|StartServers|BasicAuth|Allow|Deny|ConnectPort)[[:space:]]/d' \
    "$CONF"

# 低并发配置，适合小内存 VPS
cat >> "$CONF" <<EOF

# Custom configuration
Port $PORT
Timeout 120
MaxClients 10
MinSpareServers 1
MaxSpareServers 2
StartServers 1
BasicAuth $USERNAME $PASSWORD
ConnectPort 443
EOF

unset PASSWORD

chmod 600 "$CONF"

echo "===== 启动服务 ====="
rc-update add tinyproxy default

if ! rc-service tinyproxy restart; then
    rc-service tinyproxy start || true
fi

echo "===== 服务状态 ====="
rc-service tinyproxy status || true

echo "===== 端口监听检查 ====="
HEX=$(printf '%04X' "$PORT")
if grep -i ":$HEX" /proc/net/tcp /proc/net/tcp6; then
    echo "发现对应端口记录，请确认状态列为 0A（监听）"
else
    echo "没有发现监听记录，请检查服务日志"
    tail -n 30 /var/log/tinyproxy/tinyproxy.log 2>/dev/null || true
fi

echo
echo "===== 安装流程结束 ====="
echo "内部监听端口：$PORT"
echo "用户名：$USERNAME"
echo "最大并发连接数：10"
echo "配置文件：$CONF"
echo "请确认服务状态和端口监听正常后再测试公网代理。"
