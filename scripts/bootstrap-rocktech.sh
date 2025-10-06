#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/opt/rtk-collector"
ENV_FILE="/etc/default/rtk-collector"
SERVICE_FILE_SRC="$REPO_DIR/systemd/rtk-collector.service"
SERVICE_FILE_DST="/etc/systemd/system/rtk-collector.service"
MOSQ_CONF_DIR="/etc/mosquitto/conf.d"
MOSQ_CONF_FILE="$MOSQ_CONF_DIR/rtk.conf"

echo "[1/6] Installing OS packages…"
sudo apt update
sudo apt install -y python3-pip mosquitto mosquitto-clients

echo "[2/6] Python deps…"
python3 -m pip install --user -r "$REPO_DIR/requirements.txt"

echo "[3/6] Mosquitto config for LAN access…"
sudo mkdir -p "$MOSQ_CONF_DIR"
sudo tee "$MOSQ_CONF_FILE" >/dev/null <<'CONF'
# rtk-collector: allow LAN clients on default MQTT port
listener 1883 0.0.0.0
allow_anonymous true
# (Optional) uncomment to keep messages across restarts
# persistence true
# persistence_location /var/lib/mosquitto/
CONF
sudo systemctl restart mosquitto
sudo systemctl enable mosquitto

echo "[4/6] Environment file…"
if [ ! -f "$ENV_FILE" ]; then
  sudo tee "$ENV_FILE" >/dev/null <<'ENV'
MQTT_HOST=localhost
MQTT_PORT=1883
DEVICE_ID=isg-502-01
BASE_TOPIC=rtk
INTERVAL_SEC=5
ENV
else
  echo "  -> $ENV_FILE exists, leaving as-is."
fi

echo "[5/6] Install systemd service…"
sudo cp "$SERVICE_FILE_SRC" "$SERVICE_FILE_DST"
sudo systemctl daemon-reload
sudo systemctl enable --now rtk-collector

echo "[6/6] Status…"
ip -br -4 addr show | awk '{print $1,$3}'
sudo ss -tlnp | grep 1883 || true
systemctl --no-pager -l status rtk-collector | sed -n '1,8p'
echo "OK. From Windows connect to: mqtt://<Rocktech-IP>:1883 (no auth)"
