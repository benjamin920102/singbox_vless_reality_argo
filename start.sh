#!/bin/bash
set -e

export REALITY_PORT=${REALITY_PORT:-"80"}

cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"

export FILE_PATH="${PWD}/.npm"
export DATA_PATH="${PWD}/singbox_data"
mkdir -p "$FILE_PATH" "$DATA_PATH"

UUID_FILE="${FILE_PATH}/uuid.txt"
if [ -f "$UUID_FILE" ]; then
  UUID=$(cat "$UUID_FILE")
  echo -e "\e[1;33m[UUID] 复用固定 UUID: $UUID\e[0m"
else
  UUID=$(cat /proc/sys/kernel/random/uuid)
  echo "$UUID" > "$UUID_FILE"
  chmod 600 "$UUID_FILE"
  echo -e "\e[1;32m[UUID] 首次生成并永久保存: $UUID\e[0m"
fi

[ ! -d "${FILE_PATH}" ] && mkdir -p "${FILE_PATH}"

ARCH=$(uname -m)
BASE_URL=""
CF_ARCH=""

if [[ "$ARCH" == "arm"* ]] || [[ "$ARCH" == "aarch64" ]]; then
  BASE_URL="https://arm64.ssss.nyc.mn"
  CF_ARCH="arm64"
elif [[ "$ARCH" == "amd64"* ]] || [[ "$ARCH" == "x86_64" ]]; then
  BASE_URL="https://amd64.ssss.nyc.mn"
  CF_ARCH="amd64"
elif [[ "$ARCH" == "s390x" ]]; then
  BASE_URL="https://s390x.ssss.nyc.mn"
  CF_ARCH="s390x"
else
  echo "不支持的架构: $ARCH"
  exit 1
fi

FILE_INFOS=("sb sing-box")
declare -A FILE_MAP

download_file() {
  local URL=$1
  local FILENAME=$2
  if command -v curl >/dev/null 2>&1; then
    curl -L -sS -o "$FILENAME" "$URL" && echo -e "\e[1;32m下载 $FILENAME (curl)\e[0m"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$FILENAME" "$URL" && echo -e "\e[1;32m下载 $FILENAME (wget)\e[0m"
  else
    echo -e "\e[1;31m未找到 curl 或 wget\e[0m"
    exit 1
  fi
}

for entry in "${FILE_INFOS[@]}"; do
  URL=$(echo "$entry" | cut -d ' ' -f1)
  NAME=$(echo "$entry" | cut -d ' ' -f2)
  NEW_NAME="${FILE_PATH}/$(head /dev/urandom | tr -dc a-z0-9 | head -c6)"
  download_file "${BASE_URL}/${URL}" "$NEW_NAME"
  chmod +x "$NEW_NAME"
  FILE_MAP[$NAME]="$NEW_NAME"
done

CF_BIN="${FILE_PATH}/cloudflared"
if [ ! -f "$CF_BIN" ]; then
  download_file "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" "$CF_BIN"
  chmod +x "$CF_BIN"
fi

KEY_FILE="${FILE_PATH}/key.txt"
if [ -f "$KEY_FILE" ]; then
  echo -e "\e[1;33m[密钥] 检测到已有密钥，复用...\e[0m"
  private_key=$(grep "PrivateKey:" "$KEY_FILE" | awk '{print $2}')
  public_key=$(grep "PublicKey:" "$KEY_FILE" | awk '{print $2}')
else
  echo -e "\e[1;33m[密钥] 首次生成 Reality 密钥对...\e[0m"
  output=$("${FILE_MAP[sing-box]}" generate reality-keypair)
  echo "$output" > "$KEY_FILE"
  private_key=$(echo "$output" | awk '/PrivateKey:/ {print $2}')
  public_key=$(echo "$output" | awk '/PublicKey:/ {print $2}')
  chmod 600 "$KEY_FILE"
  echo -e "\e[1;32m[密钥] 密钥已保存，重启后保持不变\e[0m"
fi

cat > "${FILE_PATH}/config.json" <<EOF
{
  "log": { "disabled": true },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": $REALITY_PORT,
      "users": [{"uuid": "$UUID", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true,
        "server_name": "www.nazhumi.com",
        "reality": {
          "enabled": true,
          "handshake": {"server": "www.nazhumi.com", "server_port": 443},
          "private_key": "$private_key",
          "short_id": [""]
        }
      }
    }
  ],
  "outbounds": [{"type": "direct"}]
}
EOF

"${FILE_MAP[sing-box]}" run -c "${FILE_PATH}/config.json" &
SINGBOX_PID=$!
echo "[SING-BOX] 启动完成 PID=$SINGBOX_PID"

echo "[Cloudflared] 正在启动 Cloudflare Argo Tunnel..."
nohup "$CF_BIN" tunnel --url http://127.0.0.1:${REALITY_PORT} --no-autoupdate > "${FILE_PATH}/argo.log" 2>&1 &
CF_PID=$!

ARGO_DOMAIN=""
for i in {1..30}; do
  sleep 2
  ARGO_DOMAIN=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "${FILE_PATH}/argo.log" | sed 's|https://||' | tail -n 1)
  if [ -n "$ARGO_DOMAIN" ]; then
    echo -e "\e[1;32m[Cloudflared] 成功获取 Argo 域名: ${ARGO_DOMAIN}\e[0m"
    break
  fi
done

if [ -z "$ARGO_DOMAIN" ]; then
  echo -e "\e[1;31m[Cloudflared] 未能取得 Argo 域名，请检查 ${FILE_PATH}/argo.log\e[0m"
  ARGO_DOMAIN="127.0.0.1"
fi

ISP=$(curl -s --max-time 2 https://speed.cloudflare.com/meta | awk -F'"' '{print $26"-"$18}' || echo "0.0")

> "${FILE_PATH}/list.txt"
echo "vless://${UUID}@${ARGO_DOMAIN}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.nazhumi.com&fp=firefox&pbk=${public_key}&type=tcp#Argo-Reality-${ISP}" >> "${FILE_PATH}/list.txt"

base64 "${FILE_PATH}/list.txt" | tr -d '\n' > "${FILE_PATH}/sub.txt"
cat "${FILE_PATH}/list.txt"
echo -e "\n\e[1;32m${FILE_PATH}/sub.txt 已保存\e[0m"

schedule_restart() {
  echo "[定时重启:Sing-box] 已启动（北京时间 00:03）"
  LAST_RESTART_DAY=-1

  while true; do
    now_ts=$(date +%s)
    beijing_ts=$((now_ts + 28800))
    H=$(( (beijing_ts / 3600) % 24 ))
    M=$(( (beijing_ts / 60) % 60 ))
    D=$(( beijing_ts / 86400 ))

    if [ "$H" -eq 00 ] && [ "$M" -eq 03 ] && [ "$D" -ne "$LAST_RESTART_DAY" ]; then
      echo "[定时重启:Sing-box] 到达 00:03 → 重启 sing-box"
      LAST_RESTART_DAY=$D

      kill "$SINGBOX_PID" 2>/dev/null || true
      sleep 3

      "${FILE_MAP[sing-box]}" run -c "${FILE_PATH}/config.json" &
      SINGBOX_PID=$!

      echo "[Sing-box重启完成] 新 PID: $SINGBOX_PID"
    fi

    sleep 1
  done
}

schedule_restart
