
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="/etc/http-proxy"
CONF="/etc/squid/squid.conf"
INFO="/root/http-proxy-info.txt"
PORT_FILE="$BASE/port"
USER_FILE="$BASE/username"
PASS_FILE="$BASE/password"
PASSWD_FILE="$BASE/passwd"

die() { echo "错误：$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请使用 root 用户运行"
[[ -f /etc/debian_version ]] || die "仅支持 Debian 系统"

install_proxy() {
    echo "=== 安装 Squid HTTP 代理 ==="

    read -rp "VPS 内部监听端口 [3128]: " PORT
    PORT=${PORT:-3128}
    [[ "$PORT" =~ ^[0-9]+$ ]] &&
        ((PORT >= 1024 && PORT <= 65535)) ||
        die "端口必须在 1024-65535 之间"

    read -rp "代理用户名 [proxyuser]: " USERNAME
    USERNAME=${USERNAME:-proxyuser}
    [[ "$USERNAME" =~ ^[a-zA-Z0-9_.-]{1,64}$ ]] ||
        die "用户名格式不正确"

    command -v apt-get >/dev/null 2>&1 ||
        die "当前系统不支持 apt"

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y squid apache2-utils curl openssl

    local HELPER
    HELPER=$(find /usr/lib/squid -type f \
        -name basic_ncsa_auth -print -quit 2>/dev/null || true)
    [[ -n "$HELPER" && -x "$HELPER" ]] ||
        die "找不到 Squid 认证程序"

    # 保存原始配置，只在首次安装时备份
    if [[ -f "$CONF" && ! -f "$CONF.http-proxy.bak" ]]; then
        cp -a "$CONF" "$CONF.http-proxy.bak"
    fi

    install -d -m 700 "$BASE"
    local PASSWORD
    PASSWORD=$(openssl rand -hex 16)

    printf '%s\n' "$PORT" > "$PORT_FILE"
    printf '%s\n' "$USERNAME" > "$USER_FILE"
    printf '%s\n' "$PASSWORD" > "$PASS_FILE"
    chmod 600 "$PORT_FILE" "$USER_FILE" "$PASS_FILE"

    # 初始化认证文件
    htpasswd -mbc "$PASSWD_FILE" "$USERNAME" "$PASSWORD" >/dev/null
    chown proxy:proxy "$PASSWD_FILE"
    chmod 640 "$PASSWD_FILE"

    # 仅允许常规 HTTP 目标端口和 HTTPS CONNECT
    cat > "$CONF" <<EOF
http_port ${PORT}

auth_param basic program ${HELPER} ${PASSWD_FILE}
auth_param basic realm Personal-HTTP-Proxy
auth_param basic credentialsttl 1 hour
auth_param basic children 5

acl authenticated proxy_auth REQUIRED
acl Safe_ports port 80
acl Safe_ports port 443
acl SSL_ports port 443
acl CONNECT method CONNECT

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow authenticated
http_access deny all

cache deny all
access_log stdio:/var/log/squid/access.log
cache_log /var/log/squid/cache.log
coredump_dir /var/spool/squid
EOF

    if ! squid -k parse; then
        die "Squid 配置检查失败，请检查 $CONF"
    fi

    systemctl enable squid
    systemctl restart squid
    systemctl is-active --quiet squid ||
        die "Squid 未能正常启动，请检查 journalctl -u squid"

    # 若 UFW 已启用，询问是否放行内部监听端口
    if command -v ufw >/dev/null 2>&1 &&
       ufw status 2>/dev/null | grep -q "Status: active"; then
        echo
        echo "检测到 UFW 正在运行。"
        echo "如果公网映射流量需要经过本机 UFW，必须放行内部端口。"
        read -rp "是否执行 ufw allow ${PORT}/tcp？[y/N]: " OPEN
        if [[ "$OPEN" =~ ^[Yy]$ ]]; then
            ufw allow "${PORT}/tcp"
        fi
    else
        echo "未检测到启用中的 UFW，未修改本机防火墙。"
    fi

    local IP
    IP=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
    [[ -n "$IP" ]] || IP="请在服务商控制台查看公网 IP"

    {
        echo "HTTP 代理信息"
        echo "公网 IP：$IP"
        echo "内部监听端口：$PORT"
        echo "公网映射端口：请在 NAT 服务商控制台查看"
        echo "用户名：$USERNAME"
        echo "密码：$PASSWORD"
        echo "协议：HTTP Proxy"
    } > "$INFO"
    chmod 600 "$INFO"

    echo
    echo "======================================"
    echo "HTTP 代理安装成功"
    echo "公网 IP：$IP"
    echo "内部监听端口：$PORT"
    echo "用户名：$USERNAME"
    echo "密码：$PASSWORD"
    echo "======================================"
    echo "信息已保存到 $INFO（仅 root 可读）"
    echo "注意：NAT 公网端口需在服务商控制台配置映射。"
}

show_status() {
    systemctl --no-pager --full status squid || true
    echo
    if [[ -f "$PORT_FILE" ]]; then
        echo "内部监听端口：$(cat "$PORT_FILE")"
        echo "用户名：$(cat "$USER_FILE")"
        ss -lntp | grep -E ":$(cat "$PORT_FILE")[[:space:]]" || true
    else
        echo "未找到本脚本的安装记录。"
    fi
    echo
    echo "最近日志："
    journalctl -u squid -n 30 --no-pager || true
}

change_password() {
    [[ -f "$USER_FILE" && -f "$PASSWD_FILE" ]] ||
        die "未找到安装记录"
    local USERNAME PASSWORD
    USERNAME=$(cat "$USER_FILE")
    read -rsp "输入新密码（留空则自动生成）: " PASSWORD
    echo
    PASSWORD=${PASSWORD:-$(openssl rand -hex 16)}

    htpasswd -mb "$PASSWD_FILE" "$USERNAME" "$PASSWORD" >/dev/null
    printf '%s\n' "$PASSWORD" > "$PASS_FILE"
    chmod 600 "$PASS_FILE"

    squid -k parse || die "配置检查失败"
    systemctl restart squid

    echo "密码已更新。新密码：$PASSWORD"
    echo "请同步更新浏览器或 curl 的代理认证信息。"
}

uninstall_proxy() {
    echo "此操作会卸载 Squid，并删除本脚本保存的账号信息。"
    read -rp "确认卸载？请输入 YES: " ANSWER
    [[ "$ANSWER" == "YES" ]] || {
        echo "已取消"
        return
    }

    systemctl disable --now squid 2>/dev/null || true
    apt-get remove -y squid apache2-utils
    rm -rf "$BASE" "$INFO"

    # 尝试恢复安装前备份的 Squid 配置
    if [[ -f "$CONF.http-proxy.bak" ]]; then
        cp -a "$CONF.http-proxy.bak" "$CONF"
        rm -f "$CONF.http-proxy.bak"
    fi

    echo "卸载完成。未自动清理防火墙规则或 NAT 服务商的端口映射。"
}

case "${1:-install}" in
    install)   install_proxy ;;
    status)    show_status ;;
    password)  change_password ;;
    uninstall) uninstall_proxy ;;
    *)
        echo "用法：$0 {install|status|password|uninstall}"
        exit 1
        ;;
esac
