#!/usr/bin/env bash
# ===============================
# 一键 VPS 测速脚本（Ubuntu + Alpine 通用）
# 自动安装依赖并测速
# ===============================

set -e

echo "==> 检测操作系统..."
OS=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
fi

# ===============================
# 安装依赖
# ===============================
echo "==> 安装必要依赖..."
if [[ "$OS" =~ (ubuntu|debian) ]]; then
    apt update
    apt install -y curl wget ca-certificates bash python3 py3-pip
elif [[ "$OS" =~ (alpine) ]]; then
    apk add --no-cache curl wget bash python3 py3-pip ca-certificates
else
    echo "不支持的系统: $OS"
    exit 1
fi

# ===============================
# 安装 speedtest
# ===============================
echo "==> 安装 speedtest 官方版（Ookla）..."
INSTALL_OK=0

if command -v speedtest >/dev/null 2>&1; then
    # 已存在 speedtest，检测版本
    VER=$(speedtest --version 2>/dev/null || echo "")
    if [[ "$VER" =~ "1." ]]; then
        echo "speedtest 已安装: $VER"
        INSTALL_OK=1
    fi
fi

if [[ $INSTALL_OK -eq 0 ]]; then
    if [[ "$OS" =~ (ubuntu|debian) ]]; then
        curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
        apt install -y speedtest
    elif [[ "$OS" =~ (alpine) ]]; then
        # Alpine 官方没 speedtest 包，使用 Python 版本
        pip3 install --upgrade speedtest-cli
    fi
fi

# ===============================
# 测速函数
# ===============================
echo "==> 开始测速..."
if command -v speedtest >/dev/null 2>&1; then
    # 官方版
    speedtest --accept-license
else
    # Python 版
    speedtest-cli
fi

echo "==> 测速完成!"
