
#!/usr/bin/env bash
set -Eeuo pipefail

# =========================================================
# Debian 12 Squid HTTP 代理一键管理脚本
# 支持：install / status / password / uninstall
# =========================================================

BASE="/etc/http-proxy"
CONF="/etc/squid/squid.conf"
INFO="/root/http-proxy-info.txt"

PORT_FILE="$BASE/port"
USER_FILE="$BASE/username"
PASS_FILE="$BASE/password"
PASSWD_FILE="$BASE/passwd"

SERVICE="squid"
AUTH_HELPER="/usr/lib/squid/basic_ncsa_auth"

die() {
    echo "[错误] $*" >&2
    exit 1
}

log() {
    echo
    echo "[$(date '+%F %T')] $*"
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "请使用 root 用户运行此脚本"
}

check_debian() {
    [[ -r /etc/os-release ]] || die "无法识别操作系统"
    # shellcheck disable=SC1091
    source /etc/os-release

    [[ "${ID:-}" == "debian" ]] ||
        die "本脚本针对 Debian 系统设计"

    if [[ "${VERSION_ID:-}" != "12" ]]; then
        echo "[提示] 当前系统版本为 ${VERSION_ID:-unknown}，"
        echo "脚本主要针对 Debian 12 编写。"
    fi
}

read_password() {
    local p1 p2

    while true; do
        read -r -s -p "请输入代理密码（至少 12 位）: " p1
        echo
        read -r -s -p "请再次输入密码: " p2
        echo

        [[ "$p1" == "$p2" ]] || {
            echo "两次输入不一致，请重新输入。"
            continue
        }

        [[ "${#p1}" -ge 12 ]] || {
            echo "密码长度不能少于 12 位。"
            continue
        }

        [[ "$p1" != *:* ]] || {
            echo "密码不能包含冒号。"
            continue
        }

        PASSWORD="$p1"
        return
    done
}

read_username() {
    local input

    while true; do
        read -r -p "请输入代理用户名 [gentle]: " input
        USERNAME="${input:-gentle}"

        if [[ "$USERNAME" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
            return
        fi

        echo "用户名只能包含字母、数字、下划线、点和连字符。"
    done
}

read_port() {
    local input

    while true; do
        read -r -p "请输入代理端口 [3128]: " input
        PORT="${input:-3128}"

        if [[ "$PORT" =~ ^[0-9]+$ ]] &&
           (( PORT >= 1 && PORT <= 65535 )); then
            return
        fi

        echo "端口必须是 1 到 65535 之间的整数。"
    done
}

# 确保目录和文件权限正确
fix_permissions() {
    [[ -d "$BASE" ]] || die "认证目录不存在：$BASE"

    chown root:proxy "$BASE"
    chmod 750 "$BASE"

    [[ -f "$PASSWD_FILE" ]] ||
        die "认证文件不存在：$PASSWD_FILE"

    chown proxy:proxy "$PASSWD_FILE"
    chmod 640 "$PASSWD_FILE"

    # 其余信息只允许 root 读取
    for file in "$PORT_FILE" "$USER_FILE" "$PASS_FILE"; do
        if [[ -f "$file" ]]; then
            chown root:root "$file"
            chmod 600 "$file"
        fi
    done

    # 关键检查：模拟 Squid 运行用户读取认证文件
    if ! runuser -u proxy -- test -r "$PASSWD_FILE"; then
        die "Squid 用户无法读取认证文件，请检查目录及文件权限"
    fi
}

find_auth_helper() {
    if [[ -x "$AUTH_HELPER" ]]; then
        return
    fi

    AUTH_HELPER="$(find /usr/lib/squid /usr/libexec \
        -type f -name basic_ncsa_auth -executable \
        -print -quit 2>/dev/null || true)"

    [[ -n "$AUTH_HELPER" && -x "$AUTH_HELPER" ]] ||
        die "找不到 basic_ncsa_auth 认证程序"
}

write_squid_config() {
    [[ "$PORT" =~ ^[0-9]+$ ]] ||
        die "代理端口配置无效"

    cat > "$CONF" <<EOF
# Managed by /root/http-proxy.sh
http_port $PORT

auth_param basic program $AUTH_HELPER $PASSWD_FILE
auth_param basic realm Personal-HTTP-Proxy
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
visible_hostname personal-http-proxy
EOF

    chown root:root "$CONF"
    chmod 644 "$CONF"
}

check_config() {
    fix_permissions
    squid -k parse
}

restart_squid() {
    systemctl enable "$SERVICE"
    systemctl restart "$SERVICE"

    if ! systemctl is-active --quiet "$SERVICE"; then
        systemctl --no-pager --full status "$SERVICE" || true
        die "Squid 启动失败，请检查日志：journalctl -u squid -n 80"
    fi
}

save_info() {
    local ip

    ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    [[ -n "$ip" ]] || ip="请手动查询 VPS 公网 IP"

    umask 077
    cat > "$INFO" <<EOF
Squid HTTP 代理信息
===================
服务器 IP：$ip
端口：$PORT
用户名：$USERNAME
密码：请使用设置时输入的密码

HTTP 代理地址：http://$ip:$PORT
EOF

    chmod 600 "$INFO"
}

install_proxy() {
    require_root
    check_debian

    command -v apt-get >/dev/null 2>&1 ||
        die "未找到 apt-get"

    read_port
    read_username
    read_password

    log "安装依赖"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y squid apache2-utils curl

    find_auth_helper

    # 目录权限必须允许 proxy 用户进入
    install -d -o root -g proxy -m 750 "$BASE"

    printf '%s\n' "$PORT" > "$PORT_FILE"
    printf '%s\n' "$USERNAME" > "$USER_FILE"
    printf '%s\n' "$PASSWORD" > "$PASS_FILE"

    chown root:root "$PORT_FILE" "$USER_FILE" "$PASS_FILE"
    chmod 600 "$PORT_FILE" "$USER_FILE" "$PASS_FILE"

    # 创建 Squid Basic 认证数据库
    htpasswd -mbc "$PASSWD_FILE" "$USERNAME" "$PASSWORD" >/dev/null

    unset PASSWORD

    fix_permissions
    write_squid_config
    check_config
    restart_squid
    save_info

    echo
    echo "========================================"
    echo "Squid HTTP 代理安装成功"
    echo "========================================"
    echo "端口：$PORT"
    echo "用户名：$USERNAME"
    echo "认证信息已保存到：$INFO"
    echo "查看状态：bash $0 status"
    echo "修改密码：bash $0 password"
    echo
    echo "请确认云厂商安全组允许 TCP $PORT 入站。"

    if command -v ufw >/dev/null 2>&1 &&
       ufw status 2>/dev/null | grep -q "Status: active"; then
        read -r -p "检测到 UFW 已启用，是否放行 TCP $PORT？[y/N]: " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            ufw allow "$PORT/tcp"
        fi
    fi
}

status_proxy() {
    require_root

    echo "===== Squid 服务状态 ====="
    systemctl --no-pager --full status "$SERVICE" || true

    echo
    echo "===== 配置检查 ====="
    if [[ -f "$CONF" ]]; then
        squid -k parse || true
    else
        echo "配置文件不存在：$CONF"
    fi

    echo
    echo "===== 端口监听 ====="
    if command -v ss >/dev/null 2>&1; then
        ss -lntp | grep -E 'squid|:3128|:([0-9]+)' || true
    fi

    echo
    echo "===== 认证文件权限 ====="
    ls -ld "$BASE" "$PASSWD_FILE" 2>/dev/null || true

    if [[ -f "$PASSWD_FILE" ]] && id proxy >/dev/null 2>&1; then
        if runuser -u proxy -- test -r "$PASSWD_FILE"; then
            echo "认证文件可读：正常"
        else
            echo "认证文件可读：失败"
        fi
    fi

    echo
    echo "代理信息文件：$INFO"
}

change_password() {
    require_root

    [[ -f "$USER_FILE" ]] ||
        die "找不到用户名文件，请先安装代理"

    [[ -f "$PASSWD_FILE" ]] ||
        die "找不到认证文件，请先安装代理"

    USERNAME="$(cat "$USER_FILE")"

    read_password

    # 修复旧安装遗留的目录权限
    fix_permissions

    # 更新现有用户密码，不删除其他用户记录
    htpasswd -mb "$PASSWD_FILE" "$USERNAME" "$PASSWORD" >/dev/null
    unset PASSWORD

    chown proxy:proxy "$PASSWD_FILE"
    chmod 640 "$PASSWD_FILE"

    check_config
    restart_squid

    echo
    echo "代理密码修改成功。"
}

uninstall_proxy() {
    require_root

    echo "即将停止 Squid 并删除本脚本管理的代理配置。"
    read -r -p "确认卸载？输入 YES 继续: " answer
    [[ "$answer" == "YES" ]] || {
        echo "已取消。"
        return
    }

    systemctl disable --now squid 2>/dev/null || true

    # 仅删除本脚本管理的文件，不自动卸载其他软件包
    rm -rf "$BASE"
    rm -f "$INFO"

    if [[ -f "$CONF" ]] &&
       grep -q '^# Managed by /root/http-proxy.sh$' "$CONF"; then
        rm -f "$CONF"
    fi

    echo "已停止 Squid 并删除代理配置文件。"
    echo "Squid 软件包仍保留在系统中。"
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
            echo "用法：bash $0 {install|status|password|uninstall}"
            exit 1
            ;;
    esac
}

main "$@"
