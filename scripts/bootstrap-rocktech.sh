#!/usr/bin/env bash
set -euo pipefail

# Detect the user who invoked this script (even under sudo)
RUN_USER="${SUDO_USER:-$USER}"

REPO_DIR="/opt/rtk-collector"
ENV_FILE="/etc/default/rtk-collector"
SERVICE_FILE_SRC="$REPO_DIR/systemd/rtk-collector.service"
SERVICE_FILE_DST="/etc/systemd/system/rtk-collector.service"
SERVICE_DROPIN_DIR="/etc/systemd/system/rtk-collector.service.d"
SERVICE_DROPIN="$SERVICE_DROPIN_DIR/override.conf"
MOSQ_CONF_DIR="/etc/mosquitto/conf.d"
MOSQ_CONF_FILE="$MOSQ_CONF_DIR/rtk.conf"
VENV_DIR="$REPO_DIR/.venv"
ROCKTECH_IP=$(hostname -I | awk '{print $1}')

echo "[0/6] Running as: ${RUN_USER}"

echo "[1/6] Installing OS packages…"
sudo apt update
sudo apt install -y python3-venv python3-pip mosquitto mosquitto-clients python3-libgpiod

echo "[1b/6] Ensuring ${RUN_USER} is in gpio group…"
if id -nG "$RUN_USER" | grep -qw gpio; then
  echo "  -> ${RUN_USER} already in gpio group"
else
  sudo usermod -aG gpio "$RUN_USER"
  echo "  -> added ${RUN_USER} to gpio group (logout/login not required for service)"
fi

echo "[2/6] Python venv + deps…"
if [ ! -d "$VENV_DIR" ]; then
  sudo -u "$RUN_USER" python3 -m venv "$VENV_DIR"
fi
sudo -u "$RUN_USER" "$VENV_DIR/bin/pip" install --upgrade pip
sudo -u "$RUN_USER" "$VENV_DIR/bin/pip" install -r "$REPO_DIR/requirements.txt"

echo "[3/6] Mosquitto config for LAN access…"
sudo mkdir -p "$MOSQ_CONF_DIR"
sudo tee "$MOSQ_CONF_FILE" >/dev/null <<'CONF'
listener 1883 0.0.0.0
allow_anonymous true
CONF
sudo systemctl enable mosquitto
sudo systemctl restart mosquitto

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

echo "[5/6] Install/refresh systemd service (keep repo unit; override only User/Group)…"
# Install the unit from the repo, unchanged
sudo cp "$SERVICE_FILE_SRC" "$SERVICE_FILE_DST"

# Drop-in override to set the runtime user/group dynamically
sudo mkdir -p "$SERVICE_DROPIN_DIR"
sudo tee "$SERVICE_DROPIN" >/dev/null <<OVERRIDE
[Service]
User=$RUN_USER
Group=$RUN_USER
OVERRIDE

sudo systemctl daemon-reload
sudo systemctl enable rtk-collector
sudo systemctl restart rtk-collector

echo "[6/6] Status…"
ip -br -4 addr show | awk '{print $1,$3}'
sudo ss -tlnp | grep 1883 || true
systemctl --no-pager -l status rtk-collector | sed -n '1,12p'

echo
echo "OK."
echo "Running on mqtt://${ROCKTECH_IP}:1883"