# VPS Speed Test Script

一键 VPS 测速脚本，支持：

* Debian 11/12
* Ubuntu 20.04 / 22.04 / 24.04
* Alpine Linux 3.x
* x86_64
* ARM64 (Oracle ARM、Ampere 等)

功能：

* 自动检测系统
* 自动安装依赖
* 自动安装 Speedtest
* 自动处理旧版 speedtest-cli 冲突
* Cloudflare 下载测速
* 支持 Debian / Ubuntu / Alpine

---

# 使用方法

## 方式一：下载后运行（推荐）

### 下载脚本

```bash
wget -O vps_speed.sh https://cs.kyxxx.bond/vps_speed.sh
```

### 添加执行权限

```bash
chmod +x vps_speed.sh
```

### 运行

```bash
./vps_speed.sh
```

---

## 方式二：一键运行

无需保存脚本：

```bash
bash <(curl -Ls https://cs.kyxxx.bond/vps_speed.sh)
```

或者：

```bash
wget -qO- https://cs.kyxxx.bond/vps_speed.sh | bash
```

---

# 示例输出

```text
=========================================
          VPS SPEED TEST
=========================================

[INFO] Detected OS: debian

[INFO] Installing dependencies...

[INFO] Installing Ookla Speedtest...

=========================================
            SPEED TEST
=========================================

Server: Tokyo, JP
ISP: Oracle Cloud

Ping: 2.37 ms
Download: 873.52 Mbps
Upload: 612.17 Mbps

=========================================
     CLOUDFLARE DOWNLOAD TEST
=========================================

Download Speed: 109384228 bytes/sec

=========================================
              FINISHED
=========================================
```

---

# 支持系统

| 系统           | 支持 |
| ------------ | -- |
| Debian 11    | ✅  |
| Debian 12    | ✅  |
| Ubuntu 20.04 | ✅  |
| Ubuntu 22.04 | ✅  |
| Ubuntu 24.04 | ✅  |
| Alpine 3.x   | ✅  |

---

# 支持架构

| 架构              | 支持 |
| --------------- | -- |
| x86_64          | ✅  |
| ARM64 / aarch64 | ✅  |

---

# Cloudflare Pages 部署

脚本托管于 Cloudflare Pages。

更新脚本：

```bash
git add .
git commit -m "update script"
git push
```

Pages 会自动重新部署。

---

# 更新本地脚本

获取最新版：

```bash
wget -O vps_speed.sh https://cs.kyxxx.bond/vps_speed.sh
chmod +x vps_speed.sh
```

如果遇到 CDN 缓存：

```bash
wget -O vps_speed.sh "https://cs.kyxxx.bond/vps_speed.sh?t=$(date +%s)"
```

---

# 常见问题

## Alpine 出现 Killed

例如：

```text
Testing upload speed...
Killed
```

原因：

* 内存不足
* Python speedtest-cli 上传测速占用过高
* OOM Killer 终止进程

解决：

```bash
free -h
```

查看剩余内存。

---

## Debian 安装失败

如果出现：

```text
trying to overwrite '/usr/bin/speedtest'
```

说明系统已安装旧版：

```bash
apt remove -y speedtest-cli
```

然后重新运行脚本。

---

## 查看脚本内容

```bash
curl -L https://cs.kyxxx.bond/vps_speed.sh
```

---

# License

MIT License
