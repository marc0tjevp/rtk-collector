#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/opt/rtk-collector"
ENV_FILE="/etc/default/rtk-collector"
SERVICE_FILE_SRC="$REPO_DIR/systemd/influxdb.service"
SERVICE_FILE_DST="/etc/systemd/system/influxdb.service"

# Defaults (overridable via $ENV_FILE)
INFLUX_URL_DEFAULT="http://127.0.0.1:8086"
INFLUX_ORG_DEFAULT="rtk"
INFLUX_BUCKET_DEFAULT="rtk"
INFLUX_RETENTION_DEFAULT="0"   # 0 = infinite
INFLUX_ADMIN_USER_DEFAULT="admin"
# If initialized with no creds, auto-reset to recover fully hands-off.
INFLUX_AUTO_RESET_DEFAULT="true"

# --- helpers ---
upsert_env() {
  local key="$1" val="$2"
  sudo touch "$ENV_FILE"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sudo sed -i "s|^${key}=.*|${key}=${val}|g" "$ENV_FILE"
  else
    echo "${key}=${val}" | sudo tee -a "$ENV_FILE" >/dev/null
  fi
}

echo "[InfluxDB] Installing packages…"
if ! command -v influxd >/dev/null 2>&1; then
  curl -s https://repos.influxdata.com/influxdata-archive_compat.key \
  | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/influxdata-archive_compat.gpg
  echo "deb [signed-by=/etc/apt/trusted.gpg.d/influxdata-archive_compat.gpg] https://repos.influxdata.com/debian stable main" \
  | sudo tee /etc/apt/sources.list.d/influxdata.list
  sudo apt-get update
  sudo apt-get install -y influxdb2
fi

# jq to parse JSON
if ! command -v jq >/dev/null 2>&1; then
  sudo apt-get install -y jq
fi

echo "[InfluxDB] Installing systemd unit…"
sudo install -m 0644 "$SERVICE_FILE_SRC" "$SERVICE_FILE_DST"
sudo systemctl daemon-reload
sudo systemctl enable --now influxdb

echo "[InfluxDB] Waiting for API to be ready on :8086…"
for i in {1..30}; do
  if curl -sf "http://127.0.0.1:8086/health" >/dev/null; then break; fi
  sleep 1
done
echo

# Load env (if present)
if [ -f "$ENV_FILE" ]; then set -a; source "$ENV_FILE"; set +a; fi

INFLUX_URL="${INFLUX_URL:-$INFLUX_URL_DEFAULT}"
INFLUX_ORG="${INFLUX_ORG:-$INFLUX_ORG_DEFAULT}"
INFLUX_BUCKET="${INFLUX_BUCKET:-$INFLUX_BUCKET_DEFAULT}"
INFLUX_RETENTION="${INFLUX_RETENTION:-$INFLUX_RETENTION_DEFAULT}"
INFLUX_ADMIN_USER="${INFLUX_ADMIN_USER:-$INFLUX_ADMIN_USER_DEFAULT}"
INFLUX_ADMIN_PASS="${INFLUX_ADMIN_PASS:-}"   # will be generated on first setup if empty
INFLUX_AUTO_RESET="${INFLUX_AUTO_RESET:-$INFLUX_AUTO_RESET_DEFAULT}"

echo "[InfluxDB] Checking if initial setup is allowed…"
SETUP_ALLOWED="$(curl -s "${INFLUX_URL%/}/api/v2/setup" | jq -r '.allowed // empty' || true)"

TELEGRAF_TOKEN=""

do_first_setup() {
  # Ensure we have an admin password to persist
  if [ -z "$INFLUX_ADMIN_PASS" ]; then
    INFLUX_ADMIN_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)"
  fi
  echo "[InfluxDB] First-time setup (org=${INFLUX_ORG}, bucket=${INFLUX_BUCKET})…"
  SETUP_OUT="$(influx setup \
    --host "$INFLUX_URL" \
    --username "$INFLUX_ADMIN_USER" \
    --password "$INFLUX_ADMIN_PASS" \
    --org "$INFLUX_ORG" \
    --bucket "$INFLUX_BUCKET" \
    --retention "$INFLUX_RETENTION" \
    --force --json 2>&1)"
  echo "[InfluxDB] Setup output: $SETUP_OUT"
  ADMIN_TOKEN="$(echo "$SETUP_OUT" | jq -r '.auth.token' 2>/dev/null || true)"
  if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then
    echo "[ERROR] Failed to capture admin token from influx setup output"; exit 1
  fi
  echo "[InfluxDB] Creating telegraf-rw token…"
  TELEGRAF_TOKEN="$(INFLUX_TOKEN="$ADMIN_TOKEN" influx auth create \
    --host "$INFLUX_URL" \
    --org "$INFLUX_ORG" \
    --read-buckets --write-buckets \
    --description "telegraf-rw" --json | jq -r '.token')"
  if [ -z "$TELEGRAF_TOKEN" ] || [ "$TELEGRAF_TOKEN" = "null" ]; then
    echo "[ERROR] Failed to create telegraf token"; exit 1
  fi
  # Persist creds & settings
  upsert_env INFLUX_URL "$INFLUX_URL"
  upsert_env INFLUX_ORG "$INFLUX_ORG"
  upsert_env INFLUX_BUCKET "$INFLUX_BUCKET"
  upsert_env INFLUX_TOKEN "$TELEGRAF_TOKEN"
  upsert_env INFLUX_ADMIN_USER "$INFLUX_ADMIN_USER"
  upsert_env INFLUX_ADMIN_PASS "$INFLUX_ADMIN_PASS"
  sudo chmod 600 "$ENV_FILE" || true
}

if [ "$SETUP_ALLOWED" = "true" ]; then
  do_first_setup
else
  echo "[InfluxDB] Already initialized."
  if [ -n "${INFLUX_TOKEN:-}" ] && [ "$INFLUX_TOKEN" != "__SET_ME__" ]; then
    echo "[InfluxDB] Using existing INFLUX_TOKEN from $ENV_FILE"
    TELEGRAF_TOKEN="$INFLUX_TOKEN"
  else
    # Try to login with persisted admin creds (if we have them)
    if [ -n "$INFLUX_ADMIN_PASS" ]; then
      echo "[InfluxDB] Attempting CLI login with persisted admin creds…"
      if influx login --host "$INFLUX_URL" --username "$INFLUX_ADMIN_USER" --password "$INFLUX_ADMIN_PASS" --json >/dev/null 2>&1; then
        echo "[InfluxDB] Login ok. Creating new all-access token…"
        TELEGRAF_TOKEN="$(influx auth create --host "$INFLUX_URL" --org "$INFLUX_ORG" --all-access --json | jq -r '.token')"
        [ -z "$TELEGRAF_TOKEN" ] && { echo "[ERROR] Failed to mint token after login"; exit 1; }
        upsert_env INFLUX_TOKEN "$TELEGRAF_TOKEN"
        sudo chmod 600 "$ENV_FILE" || true
      else
        echo "[InfluxDB] Login failed with persisted admin creds."
      fi
    fi
    # If still no token, recover by auto-reset (destructive)
    if [ -z "$TELEGRAF_TOKEN" ]; then
      if [ "$INFLUX_AUTO_RESET" = "true" ]; then
        echo "[WARN] No usable token and cannot login. Auto-reset enabled → wiping local InfluxDB state."
        sudo systemctl stop influxdb
        sudo rm -rf /var/lib/influxdb2/*
        sudo systemctl start influxdb
        echo "[InfluxDB] Waiting for API after reset…"
        for i in {1..30}; do
          if curl -sf "http://127.0.0.1:8086/health" >/dev/null; then break; fi
          sleep 1
        done
        SETUP_ALLOWED="true"
        do_first_setup
      else
        echo "[ERROR] Initialized server with no creds and INFLUX_AUTO_RESET=false. Aborting."
        exit 1
      fi
    fi
  fi
fi

echo "[InfluxDB] Summary:"
echo "  URL:     $INFLUX_URL"
echo "  Org:     $INFLUX_ORG"
echo "  Bucket:  $INFLUX_BUCKET"
if [ -n "$TELEGRAF_TOKEN" ]; then
  echo "  Token:   present (stored in $ENV_FILE)"
else
  echo "  Token:   missing"
fi
