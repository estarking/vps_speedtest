#!/usr/bin/env bash

# ==========================================
# VPS Speed Test
# Support: Debian, Ubuntu, Alpine
# ==========================================

set -e

echo "========================================="
echo "          VPS SPEED TEST"
echo "========================================="
echo

# 获取系统类型
OS=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS="$ID"
fi

echo "[INFO] Detected OS: $OS"

# ==========================================
# 安装依赖
# ==========================================
echo
echo "[INFO] Installing dependencies..."

if [[ "$OS" =~ ^(ubuntu|debian)$ ]]; then
    apt update
    apt install -y curl wget bash ca-certificates python3 python3-pip
elif [[ "$OS" == "alpine" ]]; then
    apk update
    apk add --no-cache curl wget bash ca-certificates python3 py3-pip
else
    echo "[ERROR] Unsupported OS: $OS"
    exit 1
fi

# ==========================================
# Debian/Ubuntu 删除旧版 speedtest-cli
# ==========================================
if [[ "$OS" =~ ^(ubuntu|debian)$ ]]; then
    if dpkg -s speedtest-cli >/dev/null 2>&1; then
        echo
        echo "[INFO] Removing old speedtest-cli..."
        apt remove -y speedtest-cli || true
    fi
fi

# ==========================================
# 检查 speedtest
# ==========================================
OOKLA_INSTALLED=0
if command -v speedtest >/dev/null 2>&1; then
    VERSION=$(speedtest --version 2>/dev/null || true)
    if echo "$VERSION" | grep -qi "Ookla"; then
        OOKLA_INSTALLED=1
        echo
        echo "[INFO] Ookla Speedtest already installed"
        echo "$VERSION"
    fi
fi

# ==========================================
# 安装 Speedtest
# ==========================================
if [ "$OOKLA_INSTALLED" = "0" ]; then
    if [[ "$OS" =~ ^(ubuntu|debian)$ ]]; then
        echo
        echo "[INFO] Installing Ookla Speedtest..."
        curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
        apt update
        apt install -y speedtest
    elif [[ "$OS" == "alpine" ]]; then
        echo
        echo "[INFO] Installing Python speedtest-cli..."
        pip3 install --break-system-packages -U speedtest-cli || pip3 install -U speedtest-cli
    fi
fi

# ==========================================
# 开始测速
# ==========================================
echo
echo "========================================="
echo "            SPEED TEST"
echo "========================================="
echo

if command -v speedtest >/dev/null 2>&1; then
    if speedtest --help 2>&1 | grep -q accept-license; then
        speedtest --accept-license --accept-gdpr
    else
        speedtest
    fi
elif command -v speedtest-cli >/dev/null 2>&1; then
    speedtest-cli
else
    echo "[ERROR] No speedtest program found"
    exit 1
fi

# ==========================================
# Cloudflare Download Test
# ==========================================
echo
echo "========================================="
echo "     CLOUDFLARE DOWNLOAD TEST"
echo "========================================="
echo

curl -L -o /dev/null https://speed.cloudflare.com/__down?bytes=100000000 -w "Download Speed: %{speed_download} bytes/sec\n" --silent

echo
echo "========================================="
echo "              FINISHED"
echo "========================================="
