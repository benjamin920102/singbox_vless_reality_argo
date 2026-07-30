#!/bin/bash
set -e

export VLESS_PORT=${VLESS_PORT:-"80"}

# 強制指定工作目錄為 /root
export FILE_PATH="/root"
export DATA_PATH="/root/singbox_data"
cd "$FILE_PATH"
mkdir -p "$DATA_PATH"

UUID_FILE="${FILE_PATH}/uuid.txt"
if [ -f "$UUID_FILE" ]; then
  UUID=$(cat "$UUID_FILE")
  echo -e "\e[1;33m[UUID] 復用固定 UUID: $UUID\e[0m"
else
  UUID=$(cat /proc/sys/kernel/random/uuid)
  echo "$UUID" > "$UUID_FILE"
  chmod 600 "$UUID_FILE"
  echo -e "\e[1;32m[UUID] 首次生成並永久保存: $UUID\e[0m"
fi

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
  echo "不支持的架構: $ARCH"
  exit 1
fi

download_file() {
  local URL=$1
  local FILENAME=$2
  echo -e "\e[1;34m[下載] 正在下載 $FILENAME ...\e[0m"
  if command -v curl >/dev/null 2>&1; then
    curl -L -# -o "$FILENAME" "$URL" && echo -e "\e[1;32m[下載] $FILENAME 完成 (curl)\e[0m"
  elif command -v wget >/dev/null 2>&1; then
    wget --show-progress -q -O "$FILENAME" "$URL" && echo -e "\e[1;32m[下載] $FILENAME 完成 (wget)\e[0m"
  else
    echo -e "\e[1;31m未找到 curl 或 wget\e[0m"
    exit 1
  fi
}

# 下載 sing-box 直接存為 /root/sing-box
SINGBOX_BIN="${FILE_PATH}/sing-box"
if [ ! -f "$SINGBOX_BIN" ]; then
  download_file "${BASE_URL}/sb" "$SINGBOX_BIN"
  chmod +x "$SINGBOX_BIN"
fi

# 下載 cloudflared 直接存為 /root/cloudflared
CF_BIN="${FILE_PATH}/cloudflared"
if [ ! -f "$CF_BIN" ]; then
  download_file "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" "$CF_BIN"
  chmod +x "$CF_BIN"
fi

# 寫入 /root/config.json，加入 WebSocket 傳輸協議
cat > "${FILE_PATH}/config.json" <<EOF
{
  "log": { "disabled": true },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": $VLESS_PORT,
      "users": [
        {
          "uuid": "$UUID"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/"
      }
    }
  ],
  "outbounds": [{"type": "direct"}]
}
EOF

# 啟動 sing-box
"$SINGBOX_BIN" run -c "${FILE_PATH}/config.json" &
SINGBOX_PID=$!
echo "[SING-BOX] 啟動完成 PID=$SINGBOX_PID"

echo "[Cloudflared] 正在啟動 Cloudflare Argo Tunnel..."
nohup "$CF_BIN" tunnel --url http://127.0.0.1:${VLESS_PORT} --no-autoupdate > "${FILE_PATH}/argo.log" 2>&1 &

ARGO_DOMAIN=""
for i in {1..30}; do
  sleep 2
  ARGO_DOMAIN=$(grep -oE '[a-zA-Z0-9-]+\.trycloudflare\.com' "${FILE_PATH}/argo.log" | tail -n 1)
  if [ -n "$ARGO_DOMAIN" ]; then
    echo -e "\e[1;32m[Cloudflared] 成功獲取 Argo 域名: ${ARGO_DOMAIN}\e[0m"
    break
  fi
done

if [ -z "$ARGO_DOMAIN" ]; then
  echo -e "\e[1;31m[Cloudflared] 未能取得 Argo 域名，請檢查 ${FILE_PATH}/argo.log\e[0m"
  ARGO_DOMAIN="127.0.0.1"
fi

ISP=$(curl -s --max-time 2 https://speed.cloudflare.com/meta | awk -F'"' '{print $26"-"$18}' || echo "0.0")

> "${FILE_PATH}/list.txt"
echo "vless://${UUID}@${ARGO_DOMAIN}:443?type=ws&path=%2F&security=tls&host=${ARGO_DOMAIN}&sni=${ARGO_DOMAIN}#Argo-VLESS-${ISP}" >> "${FILE_PATH}/list.txt"

base64 "${FILE_PATH}/list.txt" | tr -d '\n' > "${FILE_PATH}/sub.txt"
echo -e "\n--- 節點連結 ---"
cat "${FILE_PATH}/list.txt"
echo -e "\n\e[1;32m${FILE_PATH}/sub.txt 已儲存\e[0m"

schedule_restart() {
  echo "[定時重啟:Sing-box] 已啟動（北京時間 00:03）"
  LAST_RESTART_DAY=-1

  while true; do
    now_ts=$(date +%s)
    beijing_ts=$((now_ts + 28800))
    H=$(( (beijing_ts / 3600) % 24 ))
    M=$(( (beijing_ts / 60) % 60 ))
    D=$(( beijing_ts / 86400 ))

    if [ "$H" -eq 0 ] && [ "$M" -eq 3 ] && [ "$D" -ne "$LAST_RESTART_DAY" ]; then
      echo "[定時重啟:Sing-box] 到達 00:03 → 重啟 sing-box"
      LAST_RESTART_DAY=$D

      kill "$SINGBOX_PID" 2>/dev/null || true
      sleep 3

      "$SINGBOX_BIN" run -c "${FILE_PATH}/config.json" &
      SINGBOX_PID=$!

      echo "[Sing-box重啟完成] 新 PID: $SINGBOX_PID"
    fi

    sleep 1
  done
}

schedule_restart
