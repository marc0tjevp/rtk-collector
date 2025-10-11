#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/opt/rtk-collector"
ENV_FILE="/etc/default/rtk-collector"

INFLUX_DS_SRC="$REPO_DIR/grafana/influxdb.yml"
DASH_PROV_SRC="$REPO_DIR/grafana/provisioning/dashboards.yml"
DASH_JSON_SRC="$REPO_DIR/grafana/dashboards/rtk.json"

require_file() {
  local f="$1"
  if [ ! -f "$f" ]; then
    echo "[ERROR] Required file missing: $f" >&2
    exit 1
  fi
}

echo "[Grafana] Installing packages…"
if ! dpkg -s grafana >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y apt-transport-https curl gnupg
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://apt.grafana.com/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    | sudo tee /etc/apt/sources.list.d/grafana.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y grafana
fi

echo "[Grafana] Wiring environment from $ENV_FILE…"
sudo mkdir -p /etc/systemd/system/grafana-server.service.d
sudo tee /etc/systemd/system/grafana-server.service.d/override.conf >/dev/null <<'EOF'
[Service]
EnvironmentFile=-/etc/default/rtk-collector
Environment=GF_EXPAND_ENV_VARS=true
EOF

# ---- REQUIRE REPO FILES (no auto-generate) ----
require_file "$INFLUX_DS_SRC"
require_file "$DASH_PROV_SRC"
require_file "$DASH_JSON_SRC"

# Load env so envsubst has values
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

echo "[Grafana] Provisioning InfluxDB v2 datasource (rendered)…"
sudo mkdir -p /etc/grafana/provisioning/datasources
# Render ${INFLUX_*} into the final file so Grafana doesn't rely on runtime env expansion
envsubst < "$INFLUX_DS_SRC" | sudo tee /etc/grafana/provisioning/datasources/influxdb.yml >/dev/null

echo "[Grafana] Provisioning dashboards…"
sudo mkdir -p /etc/grafana/provisioning/dashboards
sudo mkdir -p /etc/grafana/dashboards

sudo install -m 0644 "$DASH_PROV_SRC" \
  /etc/grafana/provisioning/dashboards/dashboards.yml

sudo install -m 0644 "$DASH_JSON_SRC" \
  /etc/grafana/dashboards/rtk.json

# Ensure grafana can read its provisioning
sudo chown -R grafana:grafana /etc/grafana/provisioning /etc/grafana/dashboards

# Optional: warn if token is unset/placeholder
if [ -f "$ENV_FILE" ]; then
  TOKEN="$(sudo sed -n 's/^INFLUX_TOKEN=//p' "$ENV_FILE" | tr -d '\r\n')"
  if [ -z "$TOKEN" ] || [ "$TOKEN" = "__SET_ME__" ]; then
    echo "[WARN] INFLUX_TOKEN not set in $ENV_FILE — datasource will fail auth until you set it."
  fi
fi

echo "[Grafana] Enabling + restarting…"
sudo systemctl daemon-reload
sudo systemctl enable --now grafana-server
sudo systemctl restart grafana-server

IP="$(hostname -I | awk '{print $1}')"
echo "[Grafana] Ready at: http://$IP:3000  (default: admin/admin)"
echo "[Grafana] Datasource + dashboard provisioned from repo files."
