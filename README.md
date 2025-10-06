# Rocktech Collector

Lightweight Python service for the Rocktech ISG-502 (Raspberry Pi 4B based).  
Publishes heartbeat, system metrics, and GPIO state snapshots to MQTT.

## Features
- Publishes every `INTERVAL_SEC` (default: 5s):
  - `heartbeat/alive` (retained)
  - `sys/cpu_temp_c`
  - `sys/load1`
  - `sys/uptime_s`
  - `sys/uptime_dhms`
  - `gpio/IO0 … IO3` (read-only snapshot of front panel pins)

- Non-invasive GPIO reads:
  - Collector opens pins `AS_IS`, reads once, and releases.
  - Does not block console control (you can still set/toggle pins yourself).
  - Works with `gpio-defaults.service` at boot (pins default LOW).

## MQTT topic structure
```
rtk/<device-id>/
  heartbeat/alive       → {"ts": 1234567890, "value": true}
  sys/cpu_temp_c        → {"ts": …, "value": 37.2}
  sys/load1             → {"ts": …, "value": 0.32}
  sys/uptime_s          → {"ts": …, "value": 84222}
  sys/uptime_dhms       → {"ts": …, "value": "0d 23h 23m 42s"}
  gpio/IO0              → {"ts": …, "value": 0}
  gpio/IO1              → {"ts": …, "value": 0}
  gpio/IO2              → {"ts": …, "value": 0}
  gpio/IO3              → {"ts": …, "value": 0}
```

## Setup

### Prerequisites
- Debian-based system (tested on ISG-502 / Raspberry Pi OS).
- `mosquitto` broker installed.
- Python 3.9+ with `venv`.

### Install
```bash
cd /opt
git clone https://github.com/marc0tjevp/rtk-collector.git
cd rtk-collector
bash scripts/bootstrap-rocktech.sh
```

This will:
- Create a Python venv.
- Install dependencies (`paho-mqtt`, `psutil`, `gpiod`).
- Install Mosquitto broker/clients.
- Set up and enable the `rtk-collector.service`.

### Run
Service runs automatically after boot:
```bash
sudo systemctl status rtk-collector
```

You can test locally:
```bash
mosquitto_sub -h localhost -t 'rtk/#' -v
```

Or connect from another host using [MQTT Explorer](https://mqtt-explorer.com/).