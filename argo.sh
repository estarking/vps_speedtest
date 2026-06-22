#!/bin/bash
# One-click Argo tunnel script
linux_os=("Debian" "Ubuntu" "CentOS" "Fedora" "Alpine")
linux_update=("apt update" "apt update" "yum -y update" "yum -y update" "apk update")
linux_install=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "apk add -f")
os_pretty=$(grep -i PRETTY_NAME /etc/os-release | cut -d \" -f2)
os_name=$(echo "$os_pretty" | awk '{print $1}')
n=0
for i in "${linux_os[@]}"
do
	if [ "$i" = "$os_name" ]
	then
		break
	else
		n=$((n + 1))
	fi
done
if [ "$n" = "5" ]
then
	echo "Current system or architecture is not supported"
	echo "Fallback to APT package manager"
	n=0
fi
if ! command -v unzip >/dev/null 2>&1
then
	${linux_update[$n]}
	${linux_install[$n]} unzip
fi
if ! command -v curl >/dev/null 2>&1
then
	${linux_update[$n]}
	${linux_install[$n]} curl
fi
if ! command -v sha256sum >/dev/null 2>&1
then
	${linux_update[$n]}
	${linux_install[$n]} coreutils
fi
if [ "$os_name" != "Alpine" ]
then
	if ! command -v systemctl >/dev/null 2>&1
	then
		${linux_update[$n]}
		${linux_install[$n]} systemctl
	fi
fi


download_file(){
	url="$1"
	output="$2"
	curl -fL --connect-timeout 10 --max-time 120 --retry 2 "$url" -o "$output" || {
		echo "Download failed: $url"
		exit 1
	}
}

sha256_file(){
	sha256sum "$1" | awk '{print $1}'
}

verify_sha256(){
	file="$1"
	expected="$2"
	actual=$(sha256_file "$file")
	if [ -z "$expected" ] || [ "$actual" != "$expected" ]
	then
		echo "SHA256 check failed: $file"
		echo "Expected: $expected"
		echo "Actual:   $actual"
		exit 1
	fi
	echo "SHA256 OK: $file"
}

get_xray_sha256(){
	asset="$1"
	dgst_file="$asset.dgst"
	download_file "https://github.com/XTLS/Xray-core/releases/latest/download/$dgst_file" "$dgst_file"
	expected=$(grep -Eo '[a-fA-F0-9]{64}' "$dgst_file" | head -n 1 | tr 'A-F' 'a-f')
	rm -f "$dgst_file"
	if [ -z "$expected" ]
	then
		echo "Could not parse Xray checksum: $dgst_file"
		exit 1
	fi
	echo "$expected"
}

get_cloudflared_sha256(){
	asset="$1"
	checksum_file="cloudflared-release.json"
	download_file "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" "$checksum_file"
	expected=$(sed -n "s/.*$asset: \([a-fA-F0-9]\{64\}\).*/\1/p" "$checksum_file" | head -n 1 | tr 'A-F' 'a-f')
	rm -f "$checksum_file"
	if [ -z "$expected" ]
	then
		echo "Could not parse cloudflared checksum for: $asset"
		exit 1
	fi
	echo "$expected"
}

download_components(){
	case "$(uname -m)" in
		x86_64 | x64 | amd64 )
		xray_asset="Xray-linux-64.zip"
		cloudflared_asset="cloudflared-linux-amd64"
		;;
		armv8 | arm64 | aarch64 )
		echo arm64
		xray_asset="Xray-linux-arm64-v8a.zip"
		cloudflared_asset="cloudflared-linux-arm64"
		;;
		* )
		echo "Current system or architecture is not supported"
		exit
		;;
	esac

	download_file "https://github.com/XTLS/Xray-core/releases/latest/download/$xray_asset" xray.zip
	verify_sha256 xray.zip "$(get_xray_sha256 "$xray_asset")"
	download_file "https://github.com/cloudflare/cloudflared/releases/latest/download/$cloudflared_asset" cloudflared-linux
	verify_sha256 cloudflared-linux "$(get_cloudflared_sha256 "$cloudflared_asset")"
}

base64_oneline(){
	if [ "$os_name" = "Alpine" ]
	then
		base64 | awk '{ORS=(NR%76==0?RS:"");}1'
	else
		base64 -w 0
	fi
}

json_value(){
	key="$1"
	sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

json_number(){
	key="$1"
	sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p"
}

get_isp_name(){
	ip_version="$1"
	meta=$(curl "-$ip_version" -s --connect-timeout 5 --max-time 10 https://speed.cloudflare.com/meta)
	if [ -z "$meta" ]
	then
		printf 'manual-ipv%s\n' "$ip_version"
		return
	fi

	colo=$(printf '%s\n' "$meta" | json_value colo | head -n 1)
	country=$(printf '%s\n' "$meta" | json_value country | head -n 1)
	asn=$(printf '%s\n' "$meta" | json_number asn | head -n 1)
	org=$(printf '%s\n' "$meta" | json_value asOrganization | head -n 1)

	name=$(printf '%s-%s-%s-%s\n' "$colo" "$country" "$asn" "$org" | sed -e 's/--*/-/g' -e 's/^-//' -e 's/-$//' -e 's/[^A-Za-z0-9._-]/_/g' -e 's/__*/_/g')
	if [ -z "$name" ]
	then
		name="manual-ipv$ip_version"
	fi
	printf '%s\n' "$name"
}

stop_pid_file(){
	pid_file="$1"
	match_text="$2"
	if [ ! -f "$pid_file" ]
	then
		return 0
	fi
	pid=$(cat "$pid_file" 2>/dev/null)
	rm -f "$pid_file"
	if ! printf '%s\n' "$pid" | grep -Eq '^[0-9]+$'
	then
		return 0
	fi
	if ps -p "$pid" -o args= 2>/dev/null | grep -Fq "$match_text"
	then
		kill "$pid" >/dev/null 2>&1 || true
		sleep 1
		kill -9 "$pid" >/dev/null 2>&1 || true
	fi
}

stop_managed_services(){
	if [ "$os_name" = "Alpine" ]
	then
		stop_pid_file /opt/argo/xray.pid "/opt/argo/xray"
		stop_pid_file /opt/argo/cloudflared.pid "/opt/argo/cloudflared-linux"
	else
		timeout 10s systemctl stop cloudflared.service >/dev/null 2>&1 || true
		timeout 10s systemctl stop xray.service >/dev/null 2>&1 || true
	fi
}

stop_quick_processes(){
	stop_pid_file .argo_quick_xray.pid "./xray/xray"
	stop_pid_file .argo_quick_cloudflared.pid "./cloudflared-linux"
}

function quicktunnel(){
rm -rf xray cloudflared-linux xray.zip
download_components
mkdir -p xray
unzip -d xray xray.zip
chmod +x cloudflared-linux xray/xray
rm -rf xray.zip
uuid=$(cat /proc/sys/kernel/random/uuid)
urlpath=$(printf '%s\n' "$uuid" | awk -F- '{print $1}')
ps_text=$(printf '%s' "$isp" | sed -e 's/_/ /g')
ps_uri=$(printf '%s' "$isp" | sed -e 's/_/%20/g' -e 's/,/%2C/g')
while true
do
	read -p "Input local Xray listen port (1-65535): " port
	if echo "$port" | grep -Eq '^[0-9]+$' && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
	then
		break
	fi
	echo "Invalid port"
done
if [ "$protocol" = "1" ]
then
cat>xray/config.json<<EOF
{
	"inbounds": [
		{
			"port": $port,
			"listen": "localhost",
			"protocol": "vmess",
			"settings": {
				"clients": [
					{
						"id": "$uuid",
						"alterId": 0
					}
				]
			},
			"streamSettings": {
				"network": "ws",
				"wsSettings": {
					"path": "$urlpath"
				}
			}
		}
	],
	"outbounds": [
		{
			"protocol": "freedom",
			"settings": {}
		}
	]
}
EOF
fi
if [ "$protocol" = "2" ]
then
cat>xray/config.json<<EOF
{
	"inbounds": [
		{
			"port": $port,
			"listen": "localhost",
			"protocol": "vless",
			"settings": {
				"decryption": "none",
				"clients": [
					{
						"id": "$uuid"
					}
				]
			},
			"streamSettings": {
				"network": "ws",
				"wsSettings": {
					"path": "$urlpath"
				}
			}
		}
	],
	"outbounds": [
		{
			"protocol": "freedom",
			"settings": {}
		}
	]
}
EOF
fi
./xray/xray run>/dev/null 2>&1 &
xray_pid=$!
printf '%s\n' "$xray_pid" > .argo_quick_xray.pid
./cloudflared-linux tunnel --url http://localhost:$port --no-autoupdate --edge-ip-version $ips --protocol http2 >argo.log 2>&1 &
cloudflared_pid=$!
printf '%s\n' "$cloudflared_pid" > .argo_quick_cloudflared.pid
sleep 1
n=0
while true
do
n=$((n + 1))
clear
echo "Waiting for Cloudflare quick tunnel URL... waited $n seconds"
argo=$(cat argo.log | grep trycloudflare.com | awk 'NR==2{print}' | awk -F// '{print $2}' | awk '{print $1}')
if [ "$n" = "15" ]
then
	n=0
	stop_pid_file .argo_quick_cloudflared.pid "./cloudflared-linux"
	rm -rf argo.log
	clear
	echo "Argo URL timed out, retrying..."
	./cloudflared-linux tunnel --url http://localhost:$port --no-autoupdate --edge-ip-version $ips --protocol http2 >argo.log 2>&1 &
	cloudflared_pid=$!
	printf '%s\n' "$cloudflared_pid" > .argo_quick_cloudflared.pid
	sleep 1
elif [ -z "$argo" ]
then
	sleep 1
else
	rm -rf argo.log
	break
fi
done
clear
if [ "$protocol" = "1" ]
then
	echo -e "VMess links generated. saas.sin.fan can be replaced with a Cloudflare preferred IP.\n" > v2ray.txt
	vmess_json=$(printf '{"add":"saas.sin.fan","aid":"0","host":"%s","id":"%s","net":"ws","path":"%s","port":"443","ps":"%s_tls","tls":"tls","type":"none","v":"2"}' "$argo" "$uuid" "$urlpath" "$ps_text")
	printf 'vmess://%s\n' "$(printf '%s' "$vmess_json" | base64_oneline)" >> v2ray.txt
	echo -e "\nPort 443 can be changed to 2053 2083 2087 2096 8443\n" >> v2ray.txt
	vmess_json=$(printf '{"add":"saas.sin.fan","aid":"0","host":"%s","id":"%s","net":"ws","path":"%s","port":"80","ps":"%s","tls":"","type":"none","v":"2"}' "$argo" "$uuid" "$urlpath" "$ps_text")
	printf 'vmess://%s\n' "$(printf '%s' "$vmess_json" | base64_oneline)" >> v2ray.txt
	echo -e "\nPort 80 can be changed to 8080 8880 2052 2082 2086 2095" >> v2ray.txt
fi
if [ "$protocol" = "2" ]
then
	echo -e "VLESS links generated. saas.sin.fan can be replaced with a Cloudflare preferred IP.\n" > v2ray.txt
	printf 'vless://%s@saas.sin.fan:443?encryption=none&security=tls&type=ws&host=%s&path=%s#%s_tls\n' "$uuid" "$argo" "$urlpath" "$ps_uri" >> v2ray.txt
	echo -e "\nPort 443 can be changed to 2053 2083 2087 2096 8443\n" >> v2ray.txt
	printf 'vless://%s@saas.sin.fan:80?encryption=none&security=none&type=ws&host=%s&path=%s#%s\n' "$uuid" "$argo" "$urlpath" "$ps_uri" >> v2ray.txt
	echo -e "\nPort 80 can be changed to 8080 8880 2052 2082 2086 2095" >> v2ray.txt
fi
rm -rf argo.log
cat v2ray.txt
echo -e "\nInfo saved to /root/v2ray.txt. Run: cat /root/v2ray.txt"
echo "Note: quick tunnel mode becomes invalid after reboot."
}

function installtunnel(){
mkdir -p /opt/argo/ >/dev/null 2>&1
rm -rf xray cloudflared-linux xray.zip
download_components
mkdir -p xray
unzip -d xray xray.zip
chmod +x cloudflared-linux xray/xray
mv cloudflared-linux "/opt/argo/"
mv xray/xray "/opt/argo/"
rm -rf xray xray.zip
uuid=$(cat /proc/sys/kernel/random/uuid)
urlpath=$(printf '%s\n' "$uuid" | awk -F- '{print $1}')
ps_text=$(printf '%s' "$isp" | sed -e 's/_/ /g')
ps_uri=$(printf '%s' "$isp" | sed -e 's/_/%20/g' -e 's/,/%2C/g')
if [ -z "$port" ]
then
	while true
	do
		read -p "Input local Xray listen port (1-65535): " port
		if echo "$port" | grep -Eq '^[0-9]+$' && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
		then
			break
		fi
		echo "Invalid port"
	done
fi
if [ "$protocol" = "1" ]
then
cat>/opt/argo/config.json<<EOF
{
	"inbounds": [
		{
			"port": $port,
			"listen": "localhost",
			"protocol": "vmess",
			"settings": {
				"clients": [
					{
						"id": "$uuid",
						"alterId": 0
					}
				]
			},
			"streamSettings": {
				"network": "ws",
				"wsSettings": {
					"path": "$urlpath"
				}
			}
		}
	],
	"outbounds": [
		{
			"protocol": "freedom",
			"settings": {}
		}
	]
}
EOF
fi
if [ "$protocol" = "2" ]
then
cat>/opt/argo/config.json<<EOF
{
	"inbounds": [
		{
			"port": $port,
			"listen": "localhost",
			"protocol": "vless",
			"settings": {
				"decryption": "none",
				"clients": [
					{
						"id": "$uuid"
					}
				]
			},
			"streamSettings": {
				"network": "ws",
				"wsSettings": {
					"path": "$urlpath"
				}
			}
		}
	],
	"outbounds": [
		{
			"protocol": "freedom",
			"settings": {}
		}
	]
}
EOF
fi
clear
echo "Manual Cloudflare Tunnel token mode"
echo "Create a Cloudflare Tunnel in the dashboard first, then set Public Hostname service to http://localhost:$port"
if [ -z "$domain" ]
then
	read -p "Input Public Hostname domain, e.g. xxx.example.com: " domain
fi
if [ -z "$domain" ]
then
	echo "Domain is empty"
	exit
elif ! printf '%s\n' "$domain" | grep -q '\.'
then
	echo "Invalid domain"
	exit
fi
if [ -z "$tunnel_token" ]
then
	read -p "Input Cloudflare Tunnel Token: " tunnel_token
fi
if [ -z "$tunnel_token" ]
then
	echo "Tunnel token is empty"
	exit
fi
printf 'TUNNEL_TOKEN=%s\n' "$tunnel_token" >/opt/argo/cloudflared.env
chmod 600 /opt/argo/cloudflared.env
cat>/opt/argo/tunnel.info<<EOF
Public Hostname: $domain
Cloudflare service: http://localhost:$port
Token file: /opt/argo/cloudflared.env
EOF
if [ "$protocol" = "1" ]
then
	echo -e "VMess links generated. saas.sin.fan can be replaced with a Cloudflare preferred IP.\n" >/opt/argo/v2ray.txt
	vmess_json=$(printf '{"add":"saas.sin.fan","aid":"0","host":"%s","id":"%s","net":"ws","path":"%s","port":"443","ps":"%s","tls":"tls","type":"none","v":"2"}' "$domain" "$uuid" "$urlpath" "$ps_text")
	printf 'vmess://%s\n' "$(printf '%s' "$vmess_json" | base64_oneline)" >>/opt/argo/v2ray.txt
	echo -e "\nPort 443 can be changed to 2053 2083 2087 2096 8443\n" >>/opt/argo/v2ray.txt
	vmess_json=$(printf '{"add":"saas.sin.fan","aid":"0","host":"%s","id":"%s","net":"ws","path":"%s","port":"80","ps":"%s","tls":"","type":"none","v":"2"}' "$domain" "$uuid" "$urlpath" "$ps_text")
	printf 'vmess://%s\n' "$(printf '%s' "$vmess_json" | base64_oneline)" >>/opt/argo/v2ray.txt
	echo -e "\nPort 80 can be changed to 8080 8880 2052 2082 2086 2095\n" >>/opt/argo/v2ray.txt
	echo "If non-TLS ports do not work, check Cloudflare SSL/TLS settings." >>/opt/argo/v2ray.txt
fi
if [ "$protocol" = "2" ]
then
	echo -e "VLESS links generated. saas.sin.fan can be replaced with a Cloudflare preferred IP.\n" >/opt/argo/v2ray.txt
	printf 'vless://%s@saas.sin.fan:443?encryption=none&security=tls&type=ws&host=%s&path=%s#%s_tls\n' "$uuid" "$domain" "$urlpath" "$ps_uri" >>/opt/argo/v2ray.txt
	echo -e "\nPort 443 can be changed to 2053 2083 2087 2096 8443\n" >>/opt/argo/v2ray.txt
	printf 'vless://%s@saas.sin.fan:80?encryption=none&security=none&type=ws&host=%s&path=%s#%s\n' "$uuid" "$domain" "$urlpath" "$ps_uri" >>/opt/argo/v2ray.txt
	echo -e "\nPort 80 can be changed to 8080 8880 2052 2082 2086 2095\n" >>/opt/argo/v2ray.txt
	echo "If non-TLS ports do not work, check Cloudflare SSL/TLS settings." >>/opt/argo/v2ray.txt
fi
rm -rf argo.log
if [ "$os_name" = "Alpine" ]
then
cat>/etc/local.d/cloudflared.start<<EOF
. /opt/argo/cloudflared.env
/opt/argo/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel --no-autoupdate run --token "\$TUNNEL_TOKEN" &
echo \$! >/opt/argo/cloudflared.pid
EOF
cat>/etc/local.d/xray.start<<EOF
/opt/argo/xray run -config /opt/argo/config.json &
echo \$! >/opt/argo/xray.pid
EOF
chmod +x /etc/local.d/cloudflared.start /etc/local.d/xray.start
rc-update add local
/etc/local.d/cloudflared.start >/dev/null 2>&1
/etc/local.d/xray.start >/dev/null 2>&1
else
#
cat>/lib/systemd/system/cloudflared.service<<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
TimeoutStartSec=0
Type=simple
EnvironmentFile=/opt/argo/cloudflared.env
ExecStart=/opt/argo/cloudflared-linux --edge-ip-version $ips --protocol http2 tunnel --no-autoupdate run --token \${TUNNEL_TOKEN}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
cat>/lib/systemd/system/xray.service<<EOF
[Unit]
Description=Xray
After=network.target

[Service]
TimeoutStartSec=0
Type=simple
ExecStart=/opt/argo/xray run -config /opt/argo/config.json
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
systemctl enable cloudflared.service >/dev/null 2>&1
systemctl enable xray.service >/dev/null 2>&1
systemctl --system daemon-reload
systemctl start cloudflared.service
systemctl start xray.service
fi
if [ "$os_name" = "Alpine" ]
then
#
cat>/opt/argo/argo.sh<<EOF
#!/bin/bash
stop_pid_file(){
	pid_file="\$1"
	match_text="\$2"
	if [ ! -f "\$pid_file" ]
	then
		return 0
	fi
	pid=\$(cat "\$pid_file" 2>/dev/null)
	rm -f "\$pid_file"
	if ! printf '%s\n' "\$pid" | grep -Eq '^[0-9]+\$'
	then
		return 0
	fi
	if ps -p "\$pid" -o args= 2>/dev/null | grep -Fq "\$match_text"
	then
		kill "\$pid" >/dev/null 2>&1 || true
		sleep 1
		kill -9 "\$pid" >/dev/null 2>&1 || true
	fi
}

stop_services(){
	stop_pid_file /opt/argo/xray.pid "/opt/argo/xray"
	stop_pid_file /opt/argo/cloudflared.pid "/opt/argo/cloudflared-linux"
}

while true
do
if [ "\$(ps -ef | grep cloudflared-linux | grep -v grep | wc -l)" = "0" ]
then
	argostatus=stop
else
	argostatus=running
fi
if [ "\$(ps -ef | grep xray | grep -v grep | wc -l)" = "0" ]
then
	xraystatus=stop
else
	xraystatus=running
fi
echo argo \$argostatus
echo xray \$xraystatus
echo "1. Show Tunnel info"
echo "2. Start services"
echo "3. Stop services"
echo "4. Restart services"
echo "5. Uninstall services"
echo "6. Show current v2ray link"
echo "0. Exit"
read -p "Select menu (default 0): " menu
if [ -z "\$menu" ]
then
	menu=0
fi
if [ "\$menu" = "1" ]
then
	clear
	cat /opt/argo/tunnel.info
	read -p "Press Enter to return menu..."
	clear
	continue
elif [ "\$menu" = "2" ]
then
	stop_services
	/etc/local.d/cloudflared.start >/dev/null 2>&1
	/etc/local.d/xray.start >/dev/null 2>&1
	clear
	sleep 1
elif [ "\$menu" = "3" ]
then
	stop_services
	clear
	sleep 2
elif [ "\$menu" = "4" ]
then
	stop_services
	/etc/local.d/cloudflared.start >/dev/null 2>&1
	/etc/local.d/xray.start >/dev/null 2>&1
	clear
	sleep 1
elif [ "\$menu" = "5" ]
then
	echo "Uninstalling local Argo services..."
	echo "Stopping processes..."
	stop_services
	echo "Removing files..."
	rm -rf /opt/argo /opt/suoha /etc/local.d/cloudflared.start /etc/local.d/xray.start /usr/bin/argo /usr/bin/suoha
	echo "All local services and shortcut commands have been removed"
	echo "If needed, delete the Tunnel manually in Cloudflare Zero Trust."
	exit
elif [ "\$menu" = "6" ]
then
	clear
	cat /opt/argo/v2ray.txt
elif [ "\$menu" = "0" ]
then
	echo "Exit successfully"
	exit
fi
done
EOF
else
#
cat>/opt/argo/argo.sh<<EOF
#!/bin/bash
clear
while true
do
echo argo \$(systemctl status cloudflared.service | sed -n '3p')
echo xray \$(systemctl status xray.service | sed -n '3p')
echo "1. Show Tunnel info"
echo "2. Start services"
echo "3. Stop services"
echo "4. Restart services"
echo "5. Uninstall services"
echo "6. Show current v2ray link"
echo "0. Exit"
read -p "Select menu (default 0): " menu
if [ -z "\$menu" ]
then
	menu=0
fi
if [ "\$menu" = "1" ]
then
	clear
	cat /opt/argo/tunnel.info
	read -p "Press Enter to return menu..."
	clear
	continue
elif [ "\$menu" = "2" ]
then
	systemctl start cloudflared.service
	systemctl start xray.service
	clear
elif [ "\$menu" = "3" ]
then
	systemctl stop cloudflared.service
	systemctl stop xray.service
	clear
elif [ "\$menu" = "4" ]
then
	systemctl restart cloudflared.service
	systemctl restart xray.service
	clear
elif [ "\$menu" = "5" ]
then
	echo "Uninstalling local Argo services..."
	echo "Stopping systemd services..."
	timeout 10s systemctl stop cloudflared.service >/dev/null 2>&1 || true
	timeout 10s systemctl stop xray.service >/dev/null 2>&1 || true
	echo "Disabling systemd services..."
	systemctl disable cloudflared.service >/dev/null 2>&1
	systemctl disable xray.service >/dev/null 2>&1
	echo "Stopping remaining service processes..."
	systemctl kill cloudflared.service >/dev/null 2>&1 || true
	systemctl kill xray.service >/dev/null 2>&1 || true
	echo "Removing files..."
	rm -rf /opt/argo /opt/suoha /usr/bin/argo /usr/bin/suoha /lib/systemd/system/cloudflared.service /lib/systemd/system/xray.service /etc/systemd/system/cloudflared.service /etc/systemd/system/xray.service /etc/systemd/system/multi-user.target.wants/cloudflared.service /etc/systemd/system/multi-user.target.wants/xray.service
	echo "Reloading systemd..."
	systemctl --system daemon-reload >/dev/null 2>&1
	systemctl reset-failed cloudflared.service xray.service >/dev/null 2>&1
	echo "All local services and shortcut commands have been removed"
	echo "If needed, delete the Tunnel manually in Cloudflare Zero Trust."
	exit
elif [ "\$menu" = "6" ]
then
	clear
	cat /opt/argo/v2ray.txt
elif [ "\$menu" = "0" ]
then
	echo "Exit successfully"
	exit
fi
done
EOF
fi
chmod +x /opt/argo/argo.sh
rm -f /usr/bin/suoha
ln -sf /opt/argo/argo.sh /usr/bin/argo
}

clear

# Print ASCII art

echo "Quick tunnel mode uses Cloudflare Quick Tunnel and does not require your own domain."
echo "Note: quick tunnel mode becomes invalid after reboot."
echo "Install service mode requires a Cloudflare-managed domain and a Tunnel token."
echo "Set the Cloudflare Public Hostname service to http://localhost:<your-port>."

echo -e "\nTT Cloudflare Tunnel one-click script\n"
echo "1. Quick tunnel mode (no Cloudflare domain, invalid after reboot)"
echo "2. Install service mode (requires Cloudflare domain, persists after reboot)"
echo "3. Uninstall service"
echo "4. Clear cache"
echo "5. Manage service"
echo "0. Exit"
read -p "Select mode (default 1): " mode
if [ -z "$mode" ]
then
	mode=1
fi
#
if [ "$mode" = "2" ]; then
    if [ -f "/usr/bin/argo" ]; then
        echo "Service is already installed. Opening management menu..."
        argo
        exit 0
    fi
fi
if [ "$mode" = "1" ]
then
	read -p "Select Xray protocol (default 1: VMess, 2: VLESS): " protocol
	if [ -z "$protocol" ]
	then
		protocol=1
	fi
	if [ "$protocol" != "1" ] && [ "$protocol" != "2" ]
	then
		echo "Invalid Xray protocol"
		exit
	fi
	read -p "Select Argo edge IP version, IPv4 or IPv6 (4 or 6, default 4): " ips
	if [ -z "$ips" ]
	then
		ips=4
	fi
	if [ "$ips" != "4" ] && [ "$ips" != "6" ]
	then
		echo "Invalid Argo edge IP version"
		exit
	fi
	isp=$(get_isp_name "$ips")
	stop_quick_processes
	rm -rf xray cloudflared-linux v2ray.txt .argo_quick_xray.pid .argo_quick_cloudflared.pid
	quicktunnel
elif [ "$mode" = "2" ]
then
	while true
	do
		read -p "Input local Xray listen port (1-65535): " port
		if echo "$port" | grep -Eq '^[0-9]+$' && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
		then
			break
		fi
		echo "Invalid port"
	done
	echo "Set Cloudflare Public Hostname service to http://localhost:$port"
	read -p "Input Public Hostname domain, e.g. xxx.example.com: " domain
	if [ -z "$domain" ]
	then
		echo "Domain is empty"
		exit
	elif ! printf '%s\n' "$domain" | grep -q '\.'
	then
		echo "Invalid domain"
		exit
	fi
	read -p "Input Cloudflare Tunnel Token: " tunnel_token
	if [ -z "$tunnel_token" ]
	then
		echo "Tunnel token is empty"
		exit
	fi
	read -p "Select Xray protocol (default 1: VMess, 2: VLESS): " protocol
	if [ -z "$protocol" ]
	then
		protocol=1
	fi
	if [ "$protocol" != "1" ] && [ "$protocol" != "2" ]
	then
		echo "Invalid Xray protocol"
		exit
	fi
	read -p "Select Argo edge IP version, IPv4 or IPv6 (4 or 6, default 4): " ips
	if [ -z "$ips" ]
	then
		ips=4
	fi
	if [ "$ips" != "4" ] && [ "$ips" != "6" ]
	then
		echo "Invalid Argo edge IP version"
		exit
	fi
	isp=$(get_isp_name "$ips")
	if [ "$os_name" = "Alpine" ]
	then
		echo "Cleaning previous local Argo services..."
		echo "Stopping processes..."
		stop_managed_services
		echo "Removing old files..."
		rm -rf /opt/argo /opt/suoha /usr/bin/argo /usr/bin/suoha /etc/local.d/cloudflared.start /etc/local.d/xray.start /lib/systemd/system/cloudflared.service /lib/systemd/system/xray.service /etc/systemd/system/cloudflared.service /etc/systemd/system/xray.service /etc/systemd/system/multi-user.target.wants/cloudflared.service /etc/systemd/system/multi-user.target.wants/xray.service
	else
		echo "Cleaning previous local Argo services..."
		echo "Stopping systemd services..."
		stop_managed_services
		echo "Disabling systemd services..."
		systemctl disable cloudflared.service >/dev/null 2>&1
		systemctl disable xray.service >/dev/null 2>&1
		echo "Removing old files..."
		rm -rf /opt/argo /opt/suoha /usr/bin/argo /usr/bin/suoha /lib/systemd/system/cloudflared.service /lib/systemd/system/xray.service /etc/systemd/system/cloudflared.service /etc/systemd/system/xray.service /etc/systemd/system/multi-user.target.wants/cloudflared.service /etc/systemd/system/multi-user.target.wants/xray.service
		echo "Reloading systemd..."
		systemctl --system daemon-reload >/dev/null 2>&1
		systemctl reset-failed cloudflared.service xray.service >/dev/null 2>&1
	fi
	installtunnel
	cat /opt/argo/v2ray.txt
	echo "Service installed. Manage it with: argo"
elif [ "$mode" = "3" ]
then
	if [ "$os_name" = "Alpine" ]
	then
		echo "Uninstalling local Argo services..."
		echo "Stopping processes..."
		stop_managed_services
		echo "Removing files..."
		rm -rf /opt/argo /opt/suoha /usr/bin/argo /usr/bin/suoha /etc/local.d/cloudflared.start /etc/local.d/xray.start /lib/systemd/system/cloudflared.service /lib/systemd/system/xray.service /etc/systemd/system/cloudflared.service /etc/systemd/system/xray.service /etc/systemd/system/multi-user.target.wants/cloudflared.service /etc/systemd/system/multi-user.target.wants/xray.service
	else
		echo "Uninstalling local Argo services..."
		echo "Stopping systemd services..."
		stop_managed_services
		echo "Disabling systemd services..."
		systemctl disable cloudflared.service >/dev/null 2>&1
		systemctl disable xray.service >/dev/null 2>&1
		echo "Removing files..."
		rm -rf /opt/argo /opt/suoha /usr/bin/argo /usr/bin/suoha /lib/systemd/system/cloudflared.service /lib/systemd/system/xray.service /etc/systemd/system/cloudflared.service /etc/systemd/system/xray.service /etc/systemd/system/multi-user.target.wants/cloudflared.service /etc/systemd/system/multi-user.target.wants/xray.service
		echo "Reloading systemd..."
		systemctl --system daemon-reload >/dev/null 2>&1
		systemctl reset-failed cloudflared.service xray.service >/dev/null 2>&1
	fi
	clear
	echo "All local services and shortcut commands have been removed"
	echo "If needed, delete the Tunnel manually in Cloudflare Zero Trust."
elif [ "$mode" = "5" ]
then
    if [ -f "/usr/bin/argo" ]; then
        argo
    else
        echo "Management command is not installed. Install service first (mode 2)."
    
    fi

elif [ "$mode" = "4" ]
then
	stop_quick_processes
	rm -rf xray cloudflared-linux v2ray.txt .argo_quick_xray.pid .argo_quick_cloudflared.pid
else
	echo "Exit successfully"
	exit
fi

    
