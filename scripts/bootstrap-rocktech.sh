#!/usr/bin/env bash
set -euo pipefail

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

echo "[0/9] Running as: ${RUN_USER}"
echo

echo "[1/9] Installing OS packages…"
sudo apt update
sudo apt install -y python3-venv python3-pip mosquitto mosquitto-clients python3-libgpiod
echo

echo "[1b/9] Ensuring ${RUN_USER} is in gpio group…"
if id -nG "$RUN_USER" | grep -qw gpio; then
  echo "  -> ${RUN_USER} already in gpio group"
else
  sudo usermod -aG gpio "$RUN_USER"
  echo "  -> added ${RUN_USER} to gpio group (logout/login not required for service)"
fi
echo

echo "[2/9] Python venv + deps…"
if [ ! -d "$VENV_DIR" ]; then
  sudo -u "$RUN_USER" python3 -m venv "$VENV_DIR"
fi
sudo -u "$RUN_USER" "$VENV_DIR/bin/pip" install --upgrade pip
sudo -u "$RUN_USER" "$VENV_DIR/bin/pip" install -r "$REPO_DIR/requirements.txt"
echo

echo "[3/9] Mosquitto config for LAN access…"
sudo mkdir -p "$MOSQ_CONF_DIR"
sudo tee "$MOSQ_CONF_FILE" >/dev/null <<'CONF'
listener 1883 0.0.0.0
allow_anonymous true
CONF
sudo systemctl enable mosquitto
sudo systemctl restart mosquitto
echo

echo "[4/9] Environment file…"
if [ ! -f "$ENV_FILE" ]; then
  sudo tee "$ENV_FILE" >/dev/null <<'ENV'
# --- MQTT ---
MQTT_HOST=localhost
MQTT_PORT=1883
MQTT_TOPICS=rtk/#

# --- Collector ---
DEVICE_ID=isg-502-01
BASE_TOPIC=rtk
INTERVAL_SEC=5

# --- InfluxDB v2 (used by Telegraf) ---
INFLUX_URL=http://127.0.0.1:8086
INFLUX_ORG=rtk
INFLUX_BUCKET=rtk
INFLUX_TOKEN=__SET_ME__
ENV
else
  echo "  -> $ENV_FILE exists, leaving as-is."
fi
echo

# --- render telegraf.conf from template ---
set -a
source "$ENV_FILE"
set +a
envsubst < "$REPO_DIR/telegraf/telegraf.conf.tmpl" > /etc/telegraf/telegraf.conf
echo "[4b/9] Rendered telegraf.conf from template using environment variables"
echo

echo "[5/9] Install/refresh systemd service (keep repo unit; override only User/Group)…"
sudo cp "$SERVICE_FILE_SRC" "$SERVICE_FILE_DST"

sudo mkdir -p "$SERVICE_DROPIN_DIR"
sudo tee "$SERVICE_DROPIN" >/dev/null <<OVERRIDE
[Service]
User=$RUN_USER
Group=$RUN_USER
OVERRIDE

sudo systemctl daemon-reload
sudo systemctl enable rtk-collector
sudo systemctl restart rtk-collector
echo

echo "[6/9] Install InfluxDB…"
bash "$REPO_DIR/scripts/install-influxdb.sh"
echo

# Warn if INFLUX_TOKEN is unset/placeholder before starting Telegraf
if [ -f "$ENV_FILE" ]; then
  set -a; source "$ENV_FILE"; set +a
  if [ "${INFLUX_TOKEN:-}" = "__SET_ME__" ] || [ -z "${INFLUX_TOKEN:-}" ]; then
    echo "[WARN] INFLUX_TOKEN is not set. Telegraf will start but cannot write to InfluxDB."
    echo "       Edit $ENV_FILE and set INFLUX_TOKEN, then: sudo systemctl restart telegraf"
  fi
fi
echo

echo "[7/9] Install Telegraf…"
bash "$REPO_DIR/scripts/install-telegraf.sh"
echo

echo "[8/9] Install Grafana…"
bash "$REPO_DIR/scripts/install-grafana.sh"

echo "[9/9] Status…"
ip -br -4 addr show | awk '{print $1,$3}'
echo
sudo ss -tlnp | grep 1883 || true
echo
systemctl --no-pager -l status rtk-collector | sed -n '1,12p'
echo
echo "--- telegraf.service (first 12 lines) ---"
systemctl --no-pager -l status telegraf | sed -n '1,12p' || true

if ! systemctl is-active --quiet telegraf; then
  echo
  echo "*** telegraf not active; recent logs: ***"
  journalctl -u telegraf -n 50 --no-pager || true
fi

echo
echo "OK."
echo "Running on mqtt://${ROCKTECH_IP}:1883"
