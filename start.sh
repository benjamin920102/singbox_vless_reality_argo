#!/bin/bash
set -e

export VLESS_PORT=${VLESS_PORT:-"80"}

# 工作目錄設為本機快取目錄，避開 NAS/CSI 掛載點權限問題
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

  chmod +x "$FILENAME"
}

# 1. 下載 Cloudflared 官方正式版 (Go 語言編譯，相容性最高)
CF_BIN="${WORK_DIR}/cloudflared"
if [ ! -f "$CF_BIN" ]; then
  CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
  download_file "$CF_URL" "$CF_BIN"
fi

# 2. 下載 Sing-box 靜態編譯版 (增加 -musl 以避免動態連結庫缺失導致的 cannot execute 錯誤)
SINGBOX_BIN="${WORK_DIR}/sing-box"
if [ ! -f "$SINGBOX_BIN" ]; then
  echo -e "\e[1;34m[下載] 正在獲取 sing-box 最新版本資訊...\e[0m"
  SB_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep -oE '"tag_name": "[^"]+"' | head -n 1 | cut -d'"' -f4 | sed 's/v//')
  if [ -z "$SB_VER" ]; then
    SB_VER="1.11.0"
  fi
  
  # 此處指定 -musl 靜態連結檔
  SB_TAR="sing-box-${SB_VER}-linux-${SB_ARCH}-musl.tar.gz"
  SB_URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/${SB_TAR}"
  
  download_file "$SB_URL" "${WORK_DIR}/${SB_TAR}"
  tar -zxvf "${WORK_DIR}/${SB_TAR}" -C "$WORK_DIR" --strip-components=1
  rm -f "${WORK_DIR}/${SB_TAR}"
  chmod +x "$SINGBOX_BIN"
fi

# 測試二進制檔是否能正常運行
echo -e "\e[1;34m[檢查] 測試二進制檔相容性...\e[0m"
if ! "$SINGBOX_BIN" version >/dev/null 2>&1; then
  echo -e "\e[1;31m[警告] sing-box 仍無法執行，嘗試強制賦予權限\e[0m"
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
  echo -e "\e[1;31m[Cloudflared] 未能取得 Argo 域名，請檢查 ${WORK_DIR}/argo.log，日誌內容如下：\e[0m"
  cat "${WORK_DIR}/argo.log"
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
