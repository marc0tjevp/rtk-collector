#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/opt/rtk-collector"
ENV_FILE="/etc/default/rtk-collector"
SERVICE_FILE_SRC="$REPO_DIR/systemd/influxdb.service"
SERVICE_FILE_DST="/etc/systemd/system/influxdb.service"

# Defaults
INFLUX_URL_DEFAULT="http://127.0.0.1:8086"
INFLUX_ORG_DEFAULT="rtk"
INFLUX_BUCKET_DEFAULT="rtk"
INFLUX_RETENTION_DEFAULT="0"
INFLUX_ADMIN_USER_DEFAULT="admin"
INFLUX_AUTO_RESET_DEFAULT="true"

# --- helpers ---
upsert_env() {
  local key="$1" val="$2"
  val="$(echo -n "$val" | tr -d '\r\n')"   # sanitize before writing
  sudo touch "$ENV_FILE"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sudo sed -i "s|^${key}=.*|${key}=${val}|g" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$val" | sudo tee -a "$ENV_FILE" >/dev/null
  fi
}

wait_health() {
  for _ in {1..30}; do
    if curl -sf "http://127.0.0.1:8086/health" >/dev/null; then return 0; fi
    sleep 1
  done
  echo "[InfluxDB] Health check timed out."
  return 1
}

fresh_reset() {
  echo "[InfluxDB] Performing full reset of local state…"
  sudo systemctl stop influxdb || true
  sudo rm -rf /root/.influxdbv2/* /var/lib/influxdb2/* ~/.influxdbv2/*
  sudo mkdir -p /var/lib/influxdb2/engine
  sudo chown -R influxdb:influxdb /var/lib/influxdb2
  sudo systemctl start influxdb
  wait_health
}

# --- install pkgs ---
echo "[InfluxDB] Installing packages…"
if ! command -v influxd >/dev/null 2>&1; then
  curl -s https://repos.influxdata.com/influxdata-archive_compat.key \
  | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/influxdata-archive_compat.gpg
  echo "deb [signed-by=/etc/apt/trusted.gpg.d/influxdata-archive_compat.gpg] https://repos.influxdata.com/debian stable main" \
  | sudo tee /etc/apt/sources.list.d/influxdata.list
  sudo apt-get update
  sudo apt-get install -y influxdb2
fi

if ! command -v jq >/dev/null 2>&1; then
  sudo apt-get install -y jq
fi

# Ensure dirs
sudo useradd -r -s /usr/sbin/nologin influxdb 2>/dev/null || true
sudo mkdir -p /var/lib/influxdb2/engine
sudo chown -R influxdb:influxdb /var/lib/influxdb2

echo "[InfluxDB] Installing systemd unit…"
sudo install -m 0644 "$SERVICE_FILE_SRC" "$SERVICE_FILE_DST"
sudo systemctl daemon-reload
sudo systemctl enable --now influxdb
wait_health || true
echo

# --- load env ---
if [ -f "$ENV_FILE" ]; then set -a; source "$ENV_FILE"; set +a; fi

INFLUX_URL="${INFLUX_URL:-$INFLUX_URL_DEFAULT}"
INFLUX_ORG="${INFLUX_ORG:-$INFLUX_ORG_DEFAULT}"
INFLUX_BUCKET="${INFLUX_BUCKET:-$INFLUX_BUCKET_DEFAULT}"
INFLUX_RETENTION="${INFLUX_RETENTION:-$INFLUX_RETENTION_DEFAULT}"
INFLUX_ADMIN_USER="${INFLUX_ADMIN_USER:-$INFLUX_ADMIN_USER_DEFAULT}"
INFLUX_ADMIN_PASS="${INFLUX_ADMIN_PASS:-}"
INFLUX_AUTO_RESET="${INFLUX_AUTO_RESET:-$INFLUX_AUTO_RESET_DEFAULT}"

if [ -z "$INFLUX_ADMIN_PASS" ]; then
  INFLUX_ADMIN_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)"
fi

echo "[InfluxDB] Checking if initial setup is allowed…"
SETUP_ALLOWED="$(curl -s "${INFLUX_URL%/}/api/v2/setup" | jq -r '.allowed // empty' || true)"

TELEGRAF_TOKEN=""

do_first_setup() {
  echo "[InfluxDB] First-time setup via API (org=${INFLUX_ORG}, bucket=${INFLUX_BUCKET})…"
  SETUP_BODY="$(jq -n \
    --arg u "$INFLUX_ADMIN_USER" \
    --arg p "$INFLUX_ADMIN_PASS" \
    --arg o "$INFLUX_ORG" \
    --arg b "$INFLUX_BUCKET" \
    --argjson r 0 \
    '{username:$u,password:$p,org:$o,bucket:$b,retentionPeriodSeconds:$r}')"

  SETUP_RES="$(curl -sS -X POST "${INFLUX_URL%/}/api/v2/setup" \
    -H 'Content-Type: application/json' \
    --data "$SETUP_BODY")"
  echo "[InfluxDB] Setup output: $SETUP_RES"

  ADMIN_TOKEN="$(echo "$SETUP_RES" | jq -r '.auth.token // empty')"
  if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" = "null" ]; then
    echo "[ERROR] No admin token in setup response"; exit 1
  fi

  # --- always persist the admin token first (safety net) ---
  upsert_env INFLUX_URL "$INFLUX_URL"
  upsert_env INFLUX_ORG "$INFLUX_ORG"
  upsert_env INFLUX_BUCKET "$INFLUX_BUCKET"
  upsert_env INFLUX_TOKEN "$ADMIN_TOKEN"
  upsert_env INFLUX_ADMIN_USER "$INFLUX_ADMIN_USER"
  upsert_env INFLUX_ADMIN_PASS "$INFLUX_ADMIN_PASS"
  sudo chmod 600 "$ENV_FILE" || true

  echo "[InfluxDB] Creating telegraf-rw token via API…"
  ORG_ID="$(echo "$SETUP_RES" | jq -r '.org.id')"
  BUCKET_ID="$(echo "$SETUP_RES" | jq -r '.bucket.id')"
  AUTH_BODY="$(jq -n \
    --arg desc "telegraf-rw" \
    --arg orgID "$ORG_ID" \
    --arg bucketID "$BUCKET_ID" \
    '{
      description:$desc,
      orgID:$orgID,
      permissions:[
        {"action":"read","resource":{"type":"buckets"}},
        {"action":"write","resource":{"type":"buckets"}}
      ]
    }')"

  TELEGRAF_TOKEN="$(curl -sS -X POST "${INFLUX_URL%/}/api/v2/authorizations" \
    -H "Authorization: Token ${ADMIN_TOKEN}" \
    -H 'Content-Type: application/json' \
    --data "$AUTH_BODY" | jq -r '.token')"

  if [ -n "$TELEGRAF_TOKEN" ] && [ "$TELEGRAF_TOKEN" != "null" ]; then
    # overwrite with telegraf token
    upsert_env INFLUX_TOKEN "$TELEGRAF_TOKEN"
    echo "[InfluxDB] Telegraf token persisted"
  else
    echo "[WARN] Failed to create telegraf token, sticking with admin token"
  fi
}

if [ "$SETUP_ALLOWED" = "true" ]; then
  do_first_setup
else
  echo "[InfluxDB] Already initialized."
  if [ -n "${INFLUX_TOKEN:-}" ] && [ "$INFLUX_TOKEN" != "__SET_ME__" ]; then
    echo "[InfluxDB] Using INFLUX_TOKEN from $ENV_FILE"
    TELEGRAF_TOKEN="$INFLUX_TOKEN"
  else
    # try reuse CLI config
    EXISTING_TOKEN="$(influx config list --json 2>/dev/null | jq -r '.default.token // empty' || true)"
    if [ -n "$EXISTING_TOKEN" ] && [ "$EXISTING_TOKEN" != "null" ]; then
      echo "[InfluxDB] Reusing token from influx CLI config"
      TELEGRAF_TOKEN="$EXISTING_TOKEN"
      upsert_env INFLUX_TOKEN "$TELEGRAF_TOKEN"
    else
      if [ "$INFLUX_AUTO_RESET" = "true" ]; then
        echo "[WARN] No usable token; auto-resetting InfluxDB"
        fresh_reset
        do_first_setup
      else
        echo "[ERROR] No usable token and auto-reset disabled"
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
