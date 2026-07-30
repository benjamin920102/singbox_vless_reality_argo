#!/bin/bash
set -e

export VLESS_PORT=${VLESS_PORT:-"80"}

# 工作目錄設為本機快取目錄，避免 NAS 掛載點的 Segfault 問題
export WORK_DIR="/tmp/singbox_run"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

UUID_FILE="${WORK_DIR}/uuid.txt"
if [ -f "$UUID_FILE" ]; then
  UUID=$(cat "$UUID_FILE")
  echo -e "\e[1;33m[UUID] 復用固定 UUID: $UUID\e[0m"
else
  UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "f23c0d8c-20ec-4f23-88fe-a76fb0c1ff36")
  echo "$UUID" > "$UUID_FILE"
  chmod 600 "$UUID_FILE" 2>/dev/null || true
  echo -e "\e[1;32m[UUID] 首次生成並永久保存: $UUID\e[0m"
fi

# 判斷 CPU 架構
ARCH=$(uname -m)
CF_ARCH=""
SB_ARCH=""

case "$ARCH" in
  x86_64|amd64)
    CF_ARCH="amd64"
    SB_ARCH="amd64"
    ;;
  aarch64|arm64)
    CF_ARCH="arm64"
    SB_ARCH="arm64"
    ;;
  s390x)
    CF_ARCH="s390x"
    SB_ARCH="s390x"
    ;;
  *)
    echo -e "\e[1;31m不支援的架構: $ARCH\e[0m"
    exit 1
    ;;
esac

# 判斷是否為 Alpine Linux (musl)
IS_MUSL=false
if [ -f /etc/alpine-release ] || ldd /bin/ls 2>&1 | grep -q musl; then
  IS_MUSL=true
  echo -e "\e[1;33m[系統偵測] 檢測到 Alpine/Musl 環境\e[0m"
fi

download_file() {
  local URL=$1
  local FILENAME=$2
  echo -e "\e[1;34m[下載] 正在下載 $FILENAME ...\e[0m"
  
  rm -f "$FILENAME"
  if command -v curl >/dev/null 2>&1; then
    curl -L -# -o "$FILENAME" "$URL"
  elif command -v wget >/dev/null 2>&1; then
    wget --show-progress -q -O "$FILENAME" "$URL"
  else
    echo -e "\e[1;31m未找到 curl 或 wget\e[0m"
    exit 1
  fi

  # 檔案小於 1MB 說明下載失敗或抓到錯誤網頁
  local FILE_SIZE=$(stat -c%s "$FILENAME" 2>/dev/null || stat -f%z "$FILENAME" 2>/dev/null || echo 0)
  if [ "$FILE_SIZE" -lt 1000000 ]; then
    echo -e "\e[1;31m[錯誤] $FILENAME 下載失敗或檔案不完整 (大小: ${FILE_SIZE} bytes)\e[0m"
    rm -f "$FILENAME"
    exit 1
  fi
  chmod +x "$FILENAME"
  echo -e "\e[1;32m[下載] $FILENAME 下載完成且校驗成功\e[0m"
}

# 1. 下載 Sing-box
SINGBOX_BIN="${WORK_DIR}/sing-box"
if [ ! -f "$SINGBOX_BIN" ]; then
  BASE_URL="https://${SB_ARCH}.ssss.nyc.mn"
  download_file "${BASE_URL}/sb" "$SINGBOX_BIN"
fi

# 2. 下載 Cloudflared (如果是 musl，使用 Cloudflare 官網的相對應版本)
CF_BIN="${WORK_DIR}/cloudflared"
if [ ! -f "$CF_BIN" ]; then
  CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
  download_file "$CF_URL" "$CF_BIN"
fi

# 寫入 config.json
cat > "${WORK_DIR}/config.json" <<EOF
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

# 啟動 Sing-box
"$SINGBOX_BIN" run -c "${WORK_DIR}/config.json" &
SINGBOX_PID=$!
echo "[SING-BOX] 啟動完成 PID=$SINGBOX_PID"

echo "[Cloudflared] 正在啟動 Cloudflare Argo Tunnel..."
nohup "$CF_BIN" tunnel --url http://127.0.0.1:${VLESS_PORT} --no-autoupdate > "${WORK_DIR}/argo.log" 2>&1 &

ARGO_DOMAIN=""
for i in {1..30}; do
  sleep 2
  ARGO_DOMAIN=$(grep -oE '[a-zA-Z0-9-]+\.trycloudflare\.com' "${WORK_DIR}/argo.log" | tail -n 1)
  if [ -n "$ARGO_DOMAIN" ]; then
    echo -e "\e[1;32m[Cloudflared] 成功獲取 Argo 域名: ${ARGO_DOMAIN}\e[0m"
    break
  fi
done

if [ -z "$ARGO_DOMAIN" ]; then
  echo -e "\e[1;31m[Cloudflared] 未能取得 Argo 域名，請檢查 ${WORK_DIR}/argo.log\e[0m"
  ARGO_DOMAIN="127.0.0.1"
fi

ISP=$(curl -s --max-time 2 https://speed.cloudflare.com/meta | awk -F'"' '{print $26"-"$18}' || echo "0.0")

> "${WORK_DIR}/list.txt"
echo "vless://${UUID}@${ARGO_DOMAIN}:443?type=ws&path=%2F&security=tls&host=${ARGO_DOMAIN}&sni=${ARGO_DOMAIN}#Argo-VLESS-${ISP}" >> "${WORK_DIR}/list.txt"

base64 "${WORK_DIR}/list.txt" | tr -d '\n' > "${WORK_DIR}/sub.txt"
echo -e "\n--- 節點連結 ---"
cat "${WORK_DIR}/list.txt"
echo -e "\n\e[1;32m${WORK_DIR}/sub.txt 已儲存至 ${WORK_DIR}/sub.txt\e[0m"

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

      "$SINGBOX_BIN" run -c "${WORK_DIR}/config.json" &
      SINGBOX_PID=$!

      echo "[Sing-box重啟完成] 新 PID: $SINGBOX_PID"
    fi

    sleep 1
  done
}

schedule_restart
