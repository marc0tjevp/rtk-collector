#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/opt/rtk-collector"
ENV_FILE="/etc/default/rtk-collector"
SERVICE_FILE_SRC="$REPO_DIR/systemd/rtk-collector.service"
SERVICE_FILE_DST="/etc/systemd/system/rtk-collector.service"

echo "[1/5] Installing OS packages…"
sudo apt update
sudo apt install -y python3-pip mosquitto mosquitto-clients

echo "[2/5] Python deps…"
python3 -m pip install --user -r "$REPO_DIR/requirements.txt"

echo "[3/5] Environment file…"
if [ ! -f "$ENV_FILE" ]; then
  sudo tee "$ENV_FILE" >/dev/null <<'ENV'
MQTT_HOST=localhost
MQTT_PORT=1883
DEVICE_ID=isg-502-01
BASE_TOPIC=rtk
INTERVAL_SEC=5
ENV
else
  echo "  -> $ENV_FILE already exists, leaving as-is."
fi

echo "[4/5] Installing systemd service…"
sudo cp "$SERVICE_FILE_SRC" "$SERVICE_FILE_DST"
sudo systemctl daemon-reload
sudo systemctl enable --now rtk-collector

echo "[5/5] Ensuring Mosquitto is running…"
sudo systemctl enable --now mosquitto

echo "Done. Check status:"
echo "  sudo systemctl status rtk-collector --no-pager -l"
echo "See messages locally:"
echo "  mosquitto_sub -h localhost -t 'rtk/#' -v"
