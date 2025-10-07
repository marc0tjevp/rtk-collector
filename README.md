# Rocktech Collector

> This is part of setting up a Rocktech ISG-502 device. [See this repo for inital setup](https://github.com/marc0tjevp/rocktech-isg-502)

Lightweight Python service for the Rocktech ISG-502 (Raspberry Pi 4B based).  
Publishes heartbeat, system metrics, and GPIO state snapshots to MQTT.  
Metrics are consumed by **Telegraf** and written to **InfluxDB v2** for storage.

---

## Features

- Publishes every `INTERVAL_SEC` (default: 5s):
  - `heartbeat/alive` → boolean
  - `sys/cpu_temp_c` → float (°C)
  - `sys/load1` → float (1-min load average)
  - `sys/uptime_s` → float (seconds since boot)
  - `sys/uptime_dhms` → string (`"0d 23h 23m 42s"`)
  - `gpio/IO0 … IO3` → int (0/1)

- Non-invasive GPIO reads:
  - Collector opens pins `AS_IS`, reads once, and releases.
  - Does not block manual `gpioset`/`gpioget`.
  - Works alongside `gpio-defaults.service` (pins default LOW at boot).

## Infrastructure

### Data flow
```
rtk-collector (Python) → MQTT (Mosquitto) → Telegraf (mqtt_consumer) → InfluxDB v2
```

### MQTT topic structure
Collector publishes Influx line protocol payloads under:
```
rtk/<device-id>/<path>
```

Examples:
```
rtk/isg-502-01/heartbeat/alive   → rtk,device=isg-502-01,group=heartbeat alive=true 1696709733345
rtk/isg-502-01/sys/cpu_temp_c    → rtk,device=isg-502-01,group=sys cpu_temp_c=37.5 1696709733345
rtk/isg-502-01/sys/load1         → rtk,device=isg-502-01,group=sys load1=0.03 1696709733345
rtk/isg-502-01/sys/uptime_s      → rtk,device=isg-502-01,group=sys uptime_s=24656.35 1696709733345
rtk/isg-502-01/sys/uptime_dhms   → rtk,device=isg-502-01,group=sys uptime_dhms="0d 6h 49m 20s" 1696709733345
rtk/isg-502-01/gpio/IO0          → rtk,device=isg-502-01,group=gpio IO0=0 1696709733345
rtk/isg-502-01/gpio/IO1          → rtk,device=isg-502-01,group=gpio IO1=0 1696709733345
```

### InfluxDB tags/fields
- **measurement:** `rtk`  
- **tags:**  
  - `device` (e.g. `isg-502-01`)  
  - `group` (e.g. `sys`, `gpio`, `heartbeat`)  
- **fields:** metric names (`cpu_temp_c`, `IO0`, `alive`, etc.)  

## Setup

```bash
cd /opt
git clone https://github.com/marc0tjevp/rtk-collector.git
cd rtk-collector
bash scripts/bootstrap-rocktech.sh
```

Bootstrap will:
- Create a Python venv.
- Install dependencies (`paho-mqtt`, `psutil`, `gpiod`).
- Install Mosquitto broker/clients.
- Install and configure InfluxDB v2.
- Render `/etc/telegraf/telegraf.conf` from `telegraf.conf.tmpl` using `/etc/default/rtk-collector`.
- Enable + start `rtk-collector.service`, `telegraf.service` and `influxdb.service`.

## Configuration

Runtime settings are defined in `/etc/default/rtk-collector`:

```ini
# MQTT
MQTT_HOST=localhost
MQTT_PORT=1883
MQTT_TOPICS=rtk/#

# Collector identity
DEVICE_ID=isg-502-01
BASE_TOPIC=rtk
INTERVAL_SEC=5

# InfluxDB v2
INFLUX_URL=http://127.0.0.1:8086
INFLUX_ORG=rtk
INFLUX_BUCKET=rtk
INFLUX_TOKEN=__SET_ME__
```
