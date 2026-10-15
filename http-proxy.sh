
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# ==========================================================
# Debian 11 / 12 Squid HTTP 代理管理脚本
# 命令：install | status | password | uninstall
# ==========================================================

BASE="/etc/http-proxy"
CONF="/etc/squid/squid.conf"
INFO="/root/http-proxy-info.txt"
PASSWD_FILE="$BASE/passwd"
STATE_PORT="$BASE/port"
STATE_USER="$BASE/username"
BACKUP_CONF="/etc/squid/squid.conf.http-proxy.bak"

die() {
    echo "[错误] $*" >&2
    exit 1
}

need_root() {
    [[ "$EUID" -eq 0 ]] || die "请使用 root 用户运行"
}

check_debian() {
    [[ -r /etc/os-release ]] || die "无法识别操作系统"
    # shellcheck disable=SC1091
    source /etc/os-release

    [[ "${ID:-}" == "debian" ]] ||
        die "本脚本仅支持 Debian 11 / 12"

    case "${VERSION_ID:-}" in
        11) echo "[系统检测] Debian 11 Bullseye" ;;
        12) echo "[系统检测] Debian 12 Bookworm" ;;
        *) die "暂不支持 Debian ${VERSION_ID:-unknown}" ;;
    esac
}

install_dependencies() {
    echo "[依赖安装] 正在更新软件源..."

    if apt-get update &&
       DEBIAN_FRONTEND=noninteractive apt-get install -y \
           squid apache2-utils curl; then
        echo "[依赖安装] 成功"
        return 0
    fi

    if [[ "${VERSION_ID:-}" != "11" ]]; then
        die "依赖安装失败，请检查 APT 软件源和网络"
    fi

    echo "[依赖安装] Debian 11 软件源可能存在 404，尝试归档安全源"

    local backup_dir f
    backup_dir="/root/apt-sources-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"

    [[ ! -f /etc/apt/sources.list ]] ||
        cp -a /etc/apt/sources.list "$backup_dir/"

    [[ ! -d /etc/apt/sources.list.d ]] ||
        cp -a /etc/apt/sources.list.d "$backup_dir/"

    # 仅修改 Debian 安全源地址，保留普通主仓库地址
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list \
             /etc/apt/sources.list.d/*.sources; do
        [[ -f "$f" ]] || continue

        sed -i \
            -e 's#https\?://security\.debian\.org/debian-security#http://archive.debian.org/debian-security#g' \
            -e 's#https\?://deb\.debian\.org/debian-security#http://archive.debian.org/debian-security#g' \
            "$f"
    done

    echo "[依赖安装] 原软件源备份：$backup_dir"

    apt-get clean
    rm -rf /var/lib/apt/lists/*

    if ! apt-get -o Acquire::Check-Valid-Until=false update; then
        die "归档软件源更新失败，请检查网络和软件源配置"
    fi

    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y \
        squid apache2-utils curl; then
        die "依赖安装仍然失败，请检查 APT 错误信息"
    fi

    echo "[依赖安装] 成功"
}

find_auth_helper() {
    local p

    for p in \
        /usr/lib/squid/basic_ncsa_auth \
        /usr/libexec/squid/basic_ncsa_auth; do
        if [[ -x "$p" ]]; then
            printf '%s\n' "$p"
            return 0
        fi
    done

    p="$(find /usr/lib/squid /usr/libexec/squid \
        -type f -name basic_ncsa_auth -perm /111 \
        -print -quit 2>/dev/null || true)"

    [[ -n "$p" ]] || return 1
    printf '%s\n' "$p"
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] &&
        (( 10#$1 >= 1024 && 10#$1 <= 65535 ))
}

valid_username() {
    [[ "$1" =~ ^[a-zA-Z0-9_.-]{1,64}$ ]]
}

# 统一设置认证目录和密码文件权限
set_auth_permissions() {
    getent group proxy >/dev/null ||
        die "系统不存在 proxy 用户组，无法设置认证文件权限"

    chown root:proxy "$BASE"
    chmod 750 "$BASE"

    if [[ -f "$PASSWD_FILE" ]]; then
        chown root:proxy "$PASSWD_FILE"
        chmod 640 "$PASSWD_FILE"
    fi
}

write_squid_config() {
    local port="$1"
    local helper="$2"

    mkdir -p /etc/squid

    # 首次修改前备份原配置
    if [[ -f "$CONF" && ! -f "$BACKUP_CONF" ]]; then
        cp -a "$CONF" "$BACKUP_CONF"
        echo "[配置] 已备份原 Squid 配置到 $BACKUP_CONF"
    fi

    cat > "$CONF" <<EOF
# Managed by http-proxy.sh
http_port ${port}

visible_hostname squid-http-proxy

auth_param basic program ${helper} ${PASSWD_FILE}
auth_param basic realm HTTP Proxy
auth_param basic credentialsttl 2 hours
auth_param basic casesensitive on

acl authenticated proxy_auth REQUIRED
acl Safe_ports port 80 443 1025-65535
acl SSL_ports port 443
acl CONNECT method CONNECT

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow authenticated
http_access deny all

cache deny all
access_log none
EOF

    chmod 644 "$CONF"

    squid -k parse || die "Squid 配置检查失败，请检查 $CONF"
}

start_service() {
    systemctl enable squid
    systemctl restart squid
    systemctl --no-pager --full status squid || true
}

save_info() {
    local ip port username password

    port="$(cat "$STATE_PORT")"
    username="$(cat "$STATE_USER")"
    password="$1"

    ip="$(curl -4 -fsS --max-time 5 \
        https://api.ipify.org 2>/dev/null || true)"
    [[ -n "$ip" ]] ||
        ip="请执行 curl -4 https://api.ipify.org 查询公网 IP"

    cat > "$INFO" <<EOF
Squid HTTP 代理连接信息
服务器地址：${ip}
端口：${port}
用户名：${username}
密码：${password}

HTTP 代理地址：http://${ip}:${port}
curl 测试：
curl -x http://${username}:密码@${ip}:${port} https://example.com
EOF

    chmod 600 "$INFO"

    echo
    echo "========== 代理连接信息 =========="
    echo "服务器地址：$ip"
    echo "代理端口：$port"
    echo "用户名：$username"
    echo "密码：$password"
    echo "连接信息文件：$INFO"
    echo "=================================="
    echo
}

do_install() {
    check_debian
    install_dependencies

    local helper port username password

    helper="$(find_auth_helper)" ||
        die "未找到 Squid 的 basic_ncsa_auth 程序"

    mkdir -p "$BASE"
    set_auth_permissions

    read -r -p "请输入代理端口（默认 3128）：" port
    port="${port:-3128}"
    valid_port "$port" || die "端口必须在 1024-65535 之间"

    read -r -p "请输入代理用户名（默认 proxyuser）：" username
    username="${username:-proxyuser}"
    valid_username "$username" ||
        die "用户名只能包含字母、数字、下划线、点和连字符"

    read -r -s -p "请输入代理密码（至少 12 位）：" password
    echo
    [[ ${#password} -ge 12 ]] || die "密码至少需要 12 位"
    [[ "$password" != *:* ]] || die "密码不能包含冒号"

    printf '%s\n' "$port" > "$STATE_PORT"
    printf '%s\n' "$username" > "$STATE_USER"
    chmod 600 "$STATE_PORT" "$STATE_USER"

    # 创建认证数据库，并设置 proxy 组可读权限
    htpasswd -b -c "$PASSWD_FILE" "$username" "$password" >/dev/null
    set_auth_permissions

    write_squid_config "$port" "$helper"
    start_service
    save_info "$password"

    echo "[完成] 安装成功"
}

do_status() {
    if [[ -f "$STATE_PORT" ]]; then
        echo "端口：$(cat "$STATE_PORT")"
        echo "用户名：$(cat "$STATE_USER" 2>/dev/null || echo 未知)"
    else
        echo "未发现本脚本管理的代理配置"
    fi

    echo
    systemctl --no-pager --full status squid 2>/dev/null || true

    if [[ -f "$STATE_PORT" ]]; then
        echo
        echo "监听端口："
        ss -lntp 2>/dev/null |
            awk -v p=":$(cat "$STATE_PORT")" 'index($4,p) {print}'
    fi

    echo
    echo "认证文件权限："
    ls -ld "$BASE" "$PASSWD_FILE" 2>/dev/null || true

    echo
    echo "Squid 配置检查："
    squid -k parse 2>&1 || true
}

do_password() {
    [[ -f "$PASSWD_FILE" && -f "$STATE_USER" ]] ||
        die "未找到代理账号，请先安装"

    local username password
    username="$(cat "$STATE_USER")"

    read -r -s -p "请输入新的代理密码（至少 12 位）：" password
    echo
    [[ ${#password} -ge 12 ]] || die "密码至少需要 12 位"
    [[ "$password" != *:* ]] || die "密码不能包含冒号"

    htpasswd -b "$PASSWD_FILE" "$username" "$password" >/dev/null

    # 每次修改密码后都重新设置正确权限
    set_auth_permissions

    squid -k parse || die "Squid 配置检查失败"
    systemctl restart squid

    save_info "$password"
    echo "[完成] 密码已修改"
}

do_uninstall() {
    echo "将停止 Squid，并删除本脚本管理的代理配置。"
    read -r -p "确认卸载？输入 YES 继续：" answer

    [[ "$answer" == "YES" ]] || {
        echo "已取消"
        return 0
    }

    systemctl disable --now squid 2>/dev/null || true

    if [[ -f "$BACKUP_CONF" ]]; then
        cp -a "$BACKUP_CONF" "$CONF"
        rm -f "$BACKUP_CONF"
        echo "已恢复原有 Squid 配置"
    else
        rm -f "$CONF"
    fi

    rm -rf "$BASE"
    rm -f "$INFO"

    if [[ -f "$CONF" ]] && squid -k parse >/dev/null 2>&1; then
        systemctl enable squid >/dev/null 2>&1 || true
        systemctl restart squid 2>/dev/null || true
    fi

    echo "[完成] 已删除代理管理配置，Squid 软件包仍保留。"
}

usage() {
    cat <<EOF
Squid HTTP 代理管理脚本

用法：
  $0 install      安装代理
  $0 status       查看状态
  $0 password     修改代理密码
  $0 uninstall    卸载代理配置
EOF
}

main() {
    need_root

    case "${1:-install}" in
        install)   do_install ;;
        status)    do_status ;;
        password)  do_password ;;
        uninstall) do_uninstall ;;
        -h|--help|help) usage ;;
        *) usage; exit 1 ;;
    esac
}

main "$@"
