#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/opt/rtk-collector"
ENV_FILE="/etc/default/rtk-collector"
SERVICE_FILE_SRC="$REPO_DIR/systemd/influxdb.service"
SERVICE_FILE_DST="/etc/systemd/system/influxdb.service"

# Defaults (will be overridden by ENV_FILE if present)
INFLUX_URL_DEFAULT="http://127.0.0.1:8086"
INFLUX_ORG_DEFAULT="rtk"
INFLUX_BUCKET_DEFAULT="rtk"
INFLUX_RETENTION_DEFAULT="0"   # 0 = infinite
INFLUX_ADMIN_USER_DEFAULT="admin"

echo "[InfluxDB] Installing packages…"
if ! command -v influxd >/dev/null 2>&1; then
  curl -s https://repos.influxdata.com/influxdata-archive_compat.key \
  | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/influxdata-archive_compat.gpg

  echo "deb [signed-by=/etc/apt/trusted.gpg.d/influxdata-archive_compat.gpg] https://repos.influxdata.com/debian stable main" \
  | sudo tee /etc/apt/sources.list.d/influxdata.list

  sudo apt-get update
  sudo apt-get install -y influxdb2
fi

# jq to parse JSON from influx CLI
if ! command -v jq >/dev/null 2>&1; then
  sudo apt-get install -y jq
fi

echo "[InfluxDB] Installing systemd unit…"
sudo install -m 0644 "$SERVICE_FILE_SRC" "$SERVICE_FILE_DST"
sudo systemctl daemon-reload
sudo systemctl enable --now influxdb

echo "[InfluxDB] Waiting for API to be ready on :8086…"
for i in {1..30}; do
  if curl -sf "http://127.0.0.1:8086/health" >/dev/null; then
    break
  fi
  sleep 1
done

# Load env (if present) for URL/ORG/BUCKET
if [ -f "$ENV_FILE" ]; then
  set -a; source "$ENV_FILE"; set +a
fi

INFLUX_URL="${INFLUX_URL:-$INFLUX_URL_DEFAULT}"
INFLUX_ORG="${INFLUX_ORG:-$INFLUX_ORG_DEFAULT}"
INFLUX_BUCKET="${INFLUX_BUCKET:-$INFLUX_BUCKET_DEFAULT}"
INFLUX_RETENTION="${INFLUX_RETENTION:-$INFLUX_RETENTION_DEFAULT}"
INFLUX_ADMIN_USER="${INFLUX_ADMIN_USER:-$INFLUX_ADMIN_USER_DEFAULT}"
# If admin pass is unset, generate one (only used at first setup)
INFLUX_ADMIN_PASS="${INFLUX_ADMIN_PASS:-}"

if [ -z "$INFLUX_ADMIN_PASS" ]; then
  # 24-char alnum
  INFLUX_ADMIN_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)"
fi

echo "[InfluxDB] Checking if initial setup is allowed…"
SETUP_JSON="$(curl -s "${INFLUX_URL%/}/api/v2/setup" || true)"
SETUP_ALLOWED="$(echo "$SETUP_JSON" | jq -r '.allowed // empty')"

TELEGRAF_TOKEN=""

if [ "$SETUP_ALLOWED" = "true" ]; then
  echo "[InfluxDB] Running first-time setup (org=${INFLUX_ORG}, bucket=${INFLUX_BUCKET})…"
  # Perform non-interactive setup; returns JSON inc. auth token
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
    echo "[ERROR] Failed to capture admin token from influx setup output"
    exit 1
  fi

  # Create a dedicated RW token for Telegraf
  echo "[InfluxDB] Creating telegraf-rw token…"
  TELEGRAF_TOKEN="$(INFLUX_TOKEN="$ADMIN_TOKEN" influx auth create \
    --host "$INFLUX_URL" \
    --org "$INFLUX_ORG" \
    --read-buckets --write-buckets \
    --description "telegraf-rw" --json | jq -r '.token')"

else
  echo "[InfluxDB] Already initialized. Ensuring telegraf-rw token exists…"

  # We need a token with permissions to list/create tokens.
  # Prefer existing INFLUX_TOKEN from env; otherwise bail with a helpful message.
  if [ -z "${INFLUX_TOKEN:-}" ] || [ "$INFLUX_TOKEN" = "__SET_ME__" ]; then
    echo "[WARN] INFLUX_TOKEN not set in $ENV_FILE; cannot manage tokens automatically."
    echo "      Set a valid admin or all-buckets RW token to manage tokens via script."
  else
    # Try to find an existing token named telegraf-rw
    EXISTING="$(INFLUX_TOKEN="$INFLUX_TOKEN" influx auth list \
      --host "$INFLUX_URL" --org "$INFLUX_ORG" --json | jq -r '.[] | select(.description=="telegraf-rw") | .token' || true)"
    if [ -n "$EXISTING" ]; then
      TELEGRAF_TOKEN="$EXISTING"
      echo "[InfluxDB] Found existing telegraf-rw token."
    else
      echo "[InfluxDB] Creating telegraf-rw token…"
      TELEGRAF_TOKEN="$(INFLUX_TOKEN="$INFLUX_TOKEN" influx auth create \
        --host "$INFLUX_URL" \
        --org "$INFLUX_ORG" \
        --read-buckets --write-buckets \
        --description "telegraf-rw" --json | jq -r '.token')"
    fi
  fi
fi

# If we have a telegraf token and env still has placeholder, write it in
if [ -n "$TELEGRAF_TOKEN" ]; then
  if [ ! -f "$ENV_FILE" ]; then
    echo "[InfluxDB] Creating $ENV_FILE with token…"
    sudo tee "$ENV_FILE" >/dev/null <<EOF
INFLUX_URL=$INFLUX_URL
INFLUX_ORG=$INFLUX_ORG
INFLUX_BUCKET=$INFLUX_BUCKET
INFLUX_TOKEN=$TELEGRAF_TOKEN
EOF
  else
    # Replace placeholder or empty token only; leave user-set value untouched
    if grep -q '^INFLUX_TOKEN=' "$ENV_FILE"; then
      CUR_TOKEN="$(grep '^INFLUX_TOKEN=' "$ENV_FILE" | cut -d= -f2- || true)"
      if [ -z "$CUR_TOKEN" ] || [ "$CUR_TOKEN" = "__SET_ME__" ]; then
        echo "[InfluxDB] Writing telegraf token into $ENV_FILE"
        sudo sed -i "s|^INFLUX_TOKEN=.*$|INFLUX_TOKEN=$TELEGRAF_TOKEN|g" "$ENV_FILE"
      fi
    else
      echo "[InfluxDB] Appending INFLUX_TOKEN to $ENV_FILE"
      echo "INFLUX_TOKEN=$TELEGRAF_TOKEN" | sudo tee -a "$ENV_FILE" >/dev/null
    fi
  fi
fi

echo "[InfluxDB] Summary:"
echo "  URL:     $INFLUX_URL"
echo "  Org:     $INFLUX_ORG"
echo "  Bucket:  $INFLUX_BUCKET"
if [ -n "$TELEGRAF_TOKEN" ]; then
  echo "  Token:   (telegraf-rw) written to $ENV_FILE (if placeholder)"
else
  echo "  Token:   unchanged (use existing INFLUX_TOKEN in $ENV_FILE)"
fi
