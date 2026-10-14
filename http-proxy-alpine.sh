
#!/bin/sh
set -eu

# Alpine Linux 轻量 HTTP 代理
# 支持 x86_64 / aarch64
# 命令：install / status / password / uninstall

BASE="/etc/3proxy-custom"
CONF="$BASE/3proxy.cfg"
PORT_FILE="$BASE/port"
USER_FILE="$BASE/username"
INIT="/etc/init.d/3proxy-http"
BIN="/usr/bin/3proxy"
EDGE_REPO="https://dl-cdn.alpinelinux.org/alpine/edge/testing"

die() {
    echo "[错误] $*" >&2
    exit 1
}

require_root() {
    [ "$(id -u)" = 0 ] || die "请使用 root 用户运行"
}

check_system() {
    [ -f /etc/alpine-release ] || die "仅支持 Alpine Linux"
    command -v apk >/dev/null 2>&1 || die "未找到 apk"

    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64|aarch64)
            echo "系统架构：$ARCH"
            ;;
        *)
            die "暂不支持架构：$ARCH"
            ;;
    esac

    id nobody >/dev/null 2>&1 ||
        die "系统缺少 nobody 用户，无法安全降权运行"
}

install_package() {
    if command -v 3proxy >/dev/null 2>&1; then
        BIN="$(command -v 3proxy)"
        echo "已检测到 3proxy：$BIN"
        return
    fi

    echo "尝试从当前 Alpine 仓库安装 3proxy..."
    if ! apk add --no-cache 3proxy; then
        echo "当前仓库未能安装，尝试 Alpine edge/testing..."
        apk add --no-cache --repository="$EDGE_REPO" 3proxy ||
            die "安装失败。请检查网络、Alpine 版本和软件包依赖"
    fi

    BIN="$(command -v 3proxy)" ||
        die "安装后仍找不到 3proxy 可执行文件"

    echo "3proxy 路径：$BIN"
}

read_port() {
    while :; do
        printf "请输入代理内部监听端口 [20027]: "
        read -r input
        PORT="${input:-20027}"

        case "$PORT" in
            ''|*[!0-9]*)
                echo "端口必须是数字。"
                continue
                ;;
        esac

        if [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
            return
        fi

        echo "端口范围为 1-65535。"
    done
}

read_username() {
    printf "请输入代理用户名 [gentle]: "
    read -r input
    USERNAME="${input:-gentle}"

    case "$USERNAME" in
        ''|*[!a-zA-Z0-9_.-]*)
            die "用户名仅允许字母、数字、点、下划线和连字符"
            ;;
    esac
}

read_password() {
    while :; do
        printf "请输入代理密码（至少 12 位）: "
        read -r -s PASSWORD
        echo

        printf "再次输入密码: "
        read -r -s PASSWORD2
        echo

        [ "$PASSWORD" = "$PASSWORD2" ] || {
            echo "两次密码不一致。"
            continue
        }

        [ "${#PASSWORD}" -ge 12 ] || {
            echo "密码至少需要 12 位。"
            continue
        }

        case "$PASSWORD" in
            *[!a-zA-Z0-9._-]*)
                echo "为避免配置解析问题，密码仅允许字母、数字、点、下划线和连字符。"
                continue
                ;;
        esac

        return
    done
}

write_config() {
    NOBODY_UID="$(id -u nobody)"
    NOBODY_GID="$(id -g nobody)"

    umask 077
    cat > "$CONF" <<EOF
# Managed by /root/3proxy.sh
maxconn 16
nscache 65536
timeouts 1 5 30 60 180 1800 15 60

users $USERNAME:CL:$PASSWORD
auth strong
allow $USERNAME

setgid $NOBODY_GID
setuid $NOBODY_UID

proxy -p$PORT
flush
EOF

    chown root:root "$CONF"
    chmod 600 "$CONF"

    printf '%s\n' "$PORT" > "$PORT_FILE"
    printf '%s\n' "$USERNAME" > "$USER_FILE"
    chown root:root "$PORT_FILE" "$USER_FILE"
    chmod 600 "$PORT_FILE" "$USER_FILE"
}

write_service() {
    cat > "$INIT" <<EOF
#!/sbin/openrc-run

name="3proxy HTTP proxy"
description="Lightweight authenticated HTTP proxy"

command="$BIN"
command_args="$CONF"
command_background="yes"
pidfile="/run/3proxy-http.pid"

depend() {
    need net
}
EOF

    chmod 755 "$INIT"
}

start_proxy() {
    # Squid 可能占用同一个端口；停止但不卸载，保留配置供回退
    if rc-service squid status >/dev/null 2>&1; then
        echo "停止 Squid，避免端口冲突..."
        rc-service squid stop || true
    fi

    rc-update del squid default >/dev/null 2>&1 || true

    rc-update add 3proxy-http default
    rc-service 3proxy-http restart ||
        rc-service 3proxy-http start ||
        die "3proxy 启动失败，请检查服务状态"

    sleep 1

    if ! rc-service 3proxy-http status >/dev/null 2>&1; then
        echo "3proxy 服务没有正常运行。"
        rc-service 3proxy-http status || true
        die "启动失败；原 Squid 配置仍保留"
    fi
}

install_proxy() {
    check_system
    install_package

    read_port
    read_username
    read_password

    install -d -m 700 "$BASE"

    write_config
    unset PASSWORD PASSWORD2
    write_service
    start_proxy

    echo
    echo "=================================="
    echo "3proxy 安装成功"
    echo "=================================="
    echo "架构：$ARCH"
    echo "监听端口：$PORT"
    echo "用户名：$USERNAME"
    echo "配置文件：$CONF"
    echo "查看状态：sh $0 status"
    echo "修改密码：sh $0 password"
    echo
    echo "请确认服务商 NAT 映射的目标端口就是 $PORT。"
    echo "公网端口可以与内部端口不同。"
}

status_proxy() {
    require_root

    echo "===== 系统信息 ====="
    uname -m
    cat /etc/alpine-release

    echo
    echo "===== 内存状态 ====="
    free -m

    echo
    echo "===== 3proxy 服务 ====="
    rc-service 3proxy-http status 2>&1 || true

    echo
    echo "===== 监听端口 ====="
    if [ -f "$PORT_FILE" ]; then
        PORT="$(cat "$PORT_FILE")"
        HEX="$(printf '%04X' "$PORT")"

        if grep -i ":$HEX" /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
            echo "发现对应端口记录：$PORT"
        else
            echo "未发现端口 $PORT 的监听记录"
        fi
    else
        echo "尚未找到端口配置"
    fi

    echo
    echo "===== 相关进程 ====="
    ps | grep '[3]proxy' || true

    echo
    echo "===== 配置权限 ====="
    ls -ld "$BASE" "$CONF" 2>/dev/null || true
}

change_password() {
    require_root
    check_system

    [ -f "$PORT_FILE" ] || die "请先安装 3proxy"
    [ -f "$USER_FILE" ] || die "找不到用户名配置"

    PORT="$(cat "$PORT_FILE")"
    USERNAME="$(cat "$USER_FILE")"

    read_password
    write_config
    unset PASSWORD PASSWORD2

    rc-service 3proxy-http restart ||
        die "配置已更新，但服务重启失败，请检查状态"

    echo "密码修改完成。"
}

uninstall_proxy() {
    require_root

    printf "确认卸载 3proxy 配置？输入 YES 确认："
    read -r answer
    [ "$answer" = "YES" ] || {
        echo "已取消。"
        return
    }

    rc-service 3proxy-http stop >/dev/null 2>&1 || true
    rc-update del 3proxy-http default >/dev/null 2>&1 || true

    rm -f "$INIT"
    rm -rf "$BASE"

    echo "3proxy 服务配置已删除。"
    echo "为避免影响其他软件，3proxy 软件包仍保留。"
    echo "Squid 没有自动恢复；如需回退，请手动启动 Squid。"
}

main() {
    require_root

    case "${1:-install}" in
        install)   install_proxy ;;
        status)    status_proxy ;;
        password)  change_password ;;
        uninstall) uninstall_proxy ;;
        *)
            echo "用法：sh $0 {install|status|password|uninstall}"
            exit 1
            ;;
    esac
}

main "$@"
