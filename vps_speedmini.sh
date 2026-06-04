#!/usr/bin/env bash

echo "========================================="
echo "          VPS SPEED TEST"
echo "========================================="
echo

# 系统信息
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "OS: $PRETTY_NAME"
fi

echo "Kernel: $(uname -r)"
echo "Arch: $(uname -m)"

echo
echo "========================================="
echo "             MEMORY"
echo "========================================="
free -h 2>/dev/null || true

echo
echo "========================================="
echo "              DISK"
echo "========================================="
df -h / 2>/dev/null || true

echo
echo "========================================="
echo "              PING"
echo "========================================="

if command -v ping >/dev/null 2>&1; then
    ping -c 4 1.1.1.1
fi

echo
echo "========================================="
echo "      CLOUDFLARE DOWNLOAD TEST"
echo "========================================="

if command -v curl >/dev/null 2>&1; then

    SPEED=$(curl -L \
        -o /dev/null \
        "https://speed.cloudflare.com/__down?bytes=50000000" \
        -w "%{speed_download}" \
        --silent)

    MBPS=$(awk "BEGIN {printf \"%.2f\", $SPEED*8/1000000}")
    MBS=$(awk "BEGIN {printf \"%.2f\", $SPEED/1000000}")

    echo "Download: ${MBPS} Mbps (${MBS} MB/s)"

elif command -v wget >/dev/null 2>&1; then

    echo "Using wget for download test..."
    wget -O /dev/null "https://speed.cloudflare.com/__down?bytes=50000000"

else

    echo "curl/wget not found"

fi

echo
echo "========================================="
echo "              FINISHED"
echo "========================================="
