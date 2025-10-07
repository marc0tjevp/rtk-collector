#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/opt/rtk-collector"
ENV_FILE="/etc/default/rtk-collector"
TELEGRAF_CONF_DIR="/etc/telegraf"
TELEGRAF_CONF="$TELEGRAF_CONF_DIR/telegraf.conf"
SERVICE_FILE_SRC="$REPO_DIR/systemd/telegraf.service"
SERVICE_FILE_DST="/etc/systemd/system/telegraf.service"

echo "[Telegraf] Installing package…"
if ! command -v telegraf >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y telegraf
fi

echo "[Telegraf] Ensuring env file exists: $ENV_FILE"
sudo test -f "$ENV_FILE" || { echo "Missing $ENV_FILE"; exit 1; }

echo "[Telegraf] Writing config from template…"
sudo mkdir -p "$TELEGRAF_CONF_DIR"
sudo bash -c '
  set -a; source "'"$ENV_FILE"'"; set +a
  envsubst < "'"$REPO_DIR"'/telegraf/telegraf.conf.tmpl" > "'"$TELEGRAF_CONF"'"
'

echo "[Telegraf] Installing systemd unit…"
sudo install -m 0644 "$SERVICE_FILE_SRC" "$SERVICE_FILE_DST"
sudo systemctl daemon-reload
sudo systemctl enable --now telegraf

echo "[Telegraf] Done. Telegraf is running and will read env from $ENV_FILE"
