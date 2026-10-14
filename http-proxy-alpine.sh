
#!/bin/sh
set -eu

# =========================================================
# Alpine Linux Squid HTTP 代理管理脚本
# 用法：sh /root/http-proxy.sh {install|status|password|uninstall}
# =========================================================

BASE="/etc/http-proxy"
CONF="/etc/squid/squid.conf"
BACKUP="/etc/squid/squid.conf.before-http-proxy"
INFO="/root/http-proxy-info.txt"

PORT_FILE="$BASE/port"
USER_FILE="$BASE/username"
PASSWD_FILE="$BASE/passwd"

SERVICE="squid"
PORT="3128"
USERNAME="gentle"
SQUID_USER=""
SQUID_GROUP=""
AUTH_HELPER=""

die() {
    echo "[错误] $*" >&2
    exit 1
}

require_root() {
    [ "$(id -u)" = "0" ] || die "请使用 root 用户运行"
}

check_alpine() {
    [ -f /etc/alpine-release ] || die "此脚本仅适用于 Alpine Linux"
    command -v apk >/dev/null 2>&1 || die "未找到 apk"
}

find_helper() {
    AUTH_HELPER="$(find /usr/lib /usr/libexec \
        -type f -name basic_ncsa_auth 2>/dev/null | head -n 1 || true)"

    [ -n "$AUTH_HELPER" ] && [ -x "$AUTH_HELPER" ] ||
        die "找不到 basic_ncsa_auth，请检查 Squid 安装"
}

find_squid_user() {
    if id squid >/dev/null 2>&1; then
        SQUID_USER="squid"
    elif id proxy >/dev/null 2>&1; then
        SQUID_USER="proxy"
    else
        die "找不到 Squid 运行用户 squid 或 proxy"
    fi

    SQUID_GROUP="$(id -gn "$SQUID_USER")"
}

read_port() {
    printf "代理端口 [3128]: "
    read -r input
    PORT="${input:-3128}"

    case "$PORT" in
        ''|*[!0-9]*) die "端口必须是数字" ;;
    esac

    [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] ||
        die "端口必须在 1-65535 范围内"
}

read_username() {
    printf "代理用户名 [gentle]: "
    read -r input
    USERNAME="${input:-gentle}"

    case "$USERNAME" in
        ''|*[!a-zA-Z0-9_.-]*)
            die "用户名只能使用字母、数字、下划线、点和连字符"
            ;;
    esac
}

fix_permissions() {
    [ -d "$BASE" ] || die "认证目录不存在：$BASE"
    [ -f "$PASSWD_FILE" ] || die "认证文件不存在：$PASSWD_FILE"

    chown "root:$SQUID_GROUP" "$BASE"
    chmod 750 "$BASE"

    chown "$SQUID_USER:$SQUID_GROUP" "$PASSWD_FILE"
    chmod 640 "$PASSWD_FILE"

    for file in "$PORT_FILE" "$USER_FILE"; do
        if [ -f "$file" ]; then
            chown root:root "$file"
            chmod 600 "$file"
        fi
    done

    # 以实际 Squid 运行用户测试认证文件读取权限
    if ! su -s /bin/sh -c "test -r '$PASSWD_FILE'" "$SQUID_USER"; then
        die "Squid 用户无法读取认证文件，拒绝继续"
    fi
}

write_config() {
    # 首次修改前备份原始配置，卸载时可以恢复
    if [ ! -f "$BACKUP" ] && [ -f "$CONF" ]; then
        cp -p "$CONF" "$BACKUP"
    fi

    cat > "$CONF" <<EOF
# Managed by /root/http-proxy.sh
http_port $PORT

auth_param basic program $AUTH_HELPER $PASSWD_FILE
auth_param basic realm Alpine-HTTP-Proxy
auth_param basic credentialsttl 2 hours
auth_param basic casesensitive on

acl authenticated proxy_auth REQUIRED

acl Safe_ports port 80
acl Safe_ports port 443
acl Safe_ports port 1025-65535

acl SSL_ports port 443
acl CONNECT method CONNECT

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow authenticated
http_access deny all

cache deny all
visible_hostname alpine-http-proxy
EOF

    chown root:root "$CONF"
    chmod 644 "$CONF"
}

check_config() {
    fix_permissions
    squid -k parse -f "$CONF"
}

restart_squid() {
    rc-update add squid default
    rc-service squid restart

    if ! rc-service squid status >/dev/null 2>&1; then
        echo "Squid 服务状态异常，最近日志："
        tail -n 50 /var/log/squid/cache.log 2>/dev/null || true
        die "Squid 启动失败"
    fi
}

save_info() {
    IP="$(wget -q -T 5 -O - https://api.ipify.org 2>/dev/null || true)"
    [ -n "$IP" ] || IP="请手动查询 VPS 公网 IP"

    umask 077
    cat > "$INFO" <<EOF
Squid HTTP 代理信息
服务器 IP：$IP
端口：$PORT
用户名：$USERNAME
代理地址：http://$IP:$PORT

密码未保存到此文件。
EOF
    chmod 600 "$INFO"
}

install_proxy() {
    require_root
    check_alpine

    read_port
    read_username

    echo
    echo "安装 Squid 及密码认证工具..."
    apk add squid apache2-utils curl

    find_helper
    find_squid_user

    install -d -o root -g "$SQUID_GROUP" -m 750 "$BASE"

    printf '%s\n' "$PORT" > "$PORT_FILE"
    printf '%s\n' "$USERNAME" > "$USER_FILE"
    chown root:root "$PORT_FILE" "$USER_FILE"
    chmod 600 "$PORT_FILE" "$USER_FILE"

    echo
    echo "请为代理用户设置密码。密码至少 12 位。"
    echo "密码由 htpasswd 交互读取，不直接显示。"

    # -c 创建认证数据库，-m 使用 Apache MD5 密码格式
    htpasswd -cm "$PASSWD_FILE" "$USERNAME"

    fix_permissions
    write_config
    check_config
    restart_squid
    save_info

    echo
    echo "=================================="
    echo "Squid HTTP 代理安装成功"
    echo "=================================="
    echo "IP：$(sed -n 's/^服务器 IP：//p' "$INFO")"
    echo "端口：$PORT"
    echo "用户名：$USERNAME"
    echo "连接地址：http://$(sed -n 's/^服务器 IP：//p' "$INFO"):$PORT"
    echo "信息文件：$INFO"
    echo
    echo "请检查 VPS 云厂商安全组是否放行 TCP $PORT。"
}

status_proxy() {
    require_root

    echo "===== Squid 服务 ====="
    rc-service squid status || true

    echo
    echo "===== 端口监听 ====="
    if command -v ss >/dev/null 2>&1; then
        ss -lntp | grep ":${PORT:-3128}" || true
    else
        netstat -lntp 2>/dev/null | grep ":${PORT:-3128}" || true
    fi

    echo
    echo "===== 认证文件权限 ====="
    ls -ld "$BASE" "$PASSWD_FILE" 2>/dev/null || true

    if id squid >/dev/null 2>&1; then
        SQUID_USER="squid"
    elif id proxy >/dev/null 2>&1; then
        SQUID_USER="proxy"
    else
        SQUID_USER=""
    fi

    if [ -n "$SQUID_USER" ] && [ -f "$PASSWD_FILE" ]; then
        if su -s /bin/sh -c "test -r '$PASSWD_FILE'" "$SQUID_USER"; then
            echo "Squid 用户可读取认证文件：正常"
        else
            echo "Squid 用户可读取认证文件：失败"
        fi
    fi

    echo
    echo "===== 配置解析 ====="
    squid -k parse -f "$CONF" 2>&1 || true
}

change_password() {
    require_root
    [ -f "$USER_FILE" ] || die "请先安装代理"
    [ -f "$PASSWD_FILE" ] || die "认证文件不存在"

    USERNAME="$(cat "$USER_FILE")"
    find_squid_user
    fix_permissions

    echo "为用户 $USERNAME 设置新密码："
    # 不使用 -c，避免重建文件并丢失其他用户记录
    htpasswd -m "$PASSWD_FILE" "$USERNAME"

    chown "$SQUID_USER:$SQUID_GROUP" "$PASSWD_FILE"
    chmod 640 "$PASSWD_FILE"

    check_config
    restart_squid

    echo "密码修改成功，Squid 已重启。"
}

uninstall_proxy() {
    require_root

    printf "确定停止 Squid 并删除代理配置？输入 YES 确认："
    read -r answer
    [ "$answer" = "YES" ] || {
        echo "已取消"
        return
    }

    rc-service squid stop 2>/dev/null || true
    rc-update del squid default 2>/dev/null || true

    if [ -f "$BACKUP" ]; then
        cp -p "$BACKUP" "$CONF"
        echo "已恢复原始 Squid 配置。"
    elif [ -f "$CONF" ] &&
         grep -q '^# Managed by /root/http-proxy.sh$' "$CONF"; then
        rm -f "$CONF"
        echo "已删除脚本生成的 Squid 配置。"
    fi

    rm -rf "$BASE"
    rm -f "$INFO"
    rm -f "$BACKUP"

    echo "代理配置已删除，Squid 软件包保留。"
    echo "如果其他业务也在使用 Squid，请先确认再操作。"
}

main() {
    require_root

    case "${1:-install}" in
        install)
            install_proxy
            ;;
        status)
            status_proxy
            ;;
        password)
            change_password
            ;;
        uninstall)
            uninstall_proxy
            ;;
        *)
            echo "用法：sh $0 {install|status|password|uninstall}"
            exit 1
            ;;
    esac
}

main "$@"
