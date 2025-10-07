import json
import os
import socket
import time
import glob
import psutil
from threading import Event
import paho.mqtt.client as mqtt
from typing import Optional
from gpiod.line import Direction, Value
import gpiod

BROKER_HOST = os.getenv("MQTT_HOST", "localhost")
BROKER_PORT = int(os.getenv("MQTT_PORT", "1883"))
DEVICE_ID = os.getenv("DEVICE_ID", socket.gethostname())
BASE_TOPIC = os.getenv("BASE_TOPIC", "rtk")
INTERVAL = int(os.getenv("INTERVAL_SEC", "5"))

PIN_IO0 = int(os.getenv("IO0_PIN", "17"))
PIN_IO1 = int(os.getenv("IO1_PIN", "18"))
PIN_IO2 = int(os.getenv("IO2_PIN", "27"))
PIN_IO3 = int(os.getenv("IO3_PIN", "22"))
PIN_MAP = {"IO0": PIN_IO0, "IO1": PIN_IO1, "IO2": PIN_IO2, "IO3": PIN_IO3}

stop = Event()

def topic(path: str) -> str:
    return f"{BASE_TOPIC}/{DEVICE_ID}/{path}"

def on_connect(client, userdata, flags=None, rc=0, *_, **__):
    print(f"[mqtt] connected rc={rc}")

def on_disconnect(client, userdata, rc=0, *_, **__):
    print(f"[mqtt] disconnected rc={rc}")

# --- line protocol helpers ---
def _esc(s: str) -> str:
    return str(s).replace(" ", r"\ ").replace(",", r"\,").replace("=", r"\=")

def _fval(v):
    if isinstance(v, bool):  return "true" if v else "false"
    if isinstance(v, int):   return f"{v}i"
    if isinstance(v, float): return repr(v)
    return '"' + str(v).replace('"', r'\"') + '"'

# fixed: Python 3.9 compatible
def _to_line_protocol(device_id: str, path: str, value, ts_ns: Optional[int] = None) -> str:
    parts = path.split("/", 1)
    group = parts[0] if parts else "misc"
    field = parts[1] if len(parts) > 1 else parts[0]
    tags = f"device={_esc(device_id)},group={_esc(group)}"
    ts = time.time_ns() if ts_ns is None else ts_ns
    return f"rtk,{tags} {_esc(field)}={_fval(value)} {ts}"

# --- publish: LP payload, topics unchanged ---
def publish(client, path, value, retain=False):
    try:
        line = _to_line_protocol(DEVICE_ID, path, value, time.time_ns())
        return client.publish(topic(path), line, qos=1, retain=retain)
    except Exception:
        return client.publish(topic(path), str(value), qos=1, retain=retain)

def format_dhms(seconds: float) -> str:
    secs = int(seconds)
    d, r = divmod(secs, 86400)
    h, r = divmod(r, 3600)
    m, s = divmod(r, 60)
    return f"{d}d {h}h {m}m {s}s"

def get_cpu_temp_c() -> Optional[float]:
    try:
        temps = psutil.sensors_temperatures()
        for key in ("cpu-thermal", "cpu_thermal", "coretemp", "soc_thermal"):
            arr = temps.get(key)
            if arr and len(arr) and hasattr(arr[0], "current"):
                return float(arr[0].current)
    except Exception:
        pass
    try:
        for zone in glob.glob("/sys/class/thermal/thermal_zone*"):
            tfile = os.path.join(zone, "temp")
            if os.path.exists(tfile):
                with open(tfile) as f:
                    raw = f.read().strip()
                if raw:
                    val = float(raw)
                    return val / 1000.0 if val > 200 else val
    except Exception:
        pass
    try:
        import subprocess
        out = subprocess.check_output(["vcgencmd", "measure_temp"], text=True).strip()
        if "temp=" in out:
            return float(out.split("temp=")[1].split("'")[0])
    except Exception:
        pass
    return None

def read_gpio_snapshot() -> dict:
    cfg = {pin: gpiod.LineSettings(direction=Direction.AS_IS) for pin in PIN_MAP.values()}
    req = gpiod.request_lines("/dev/gpiochip0", consumer="rtk-collector", config=cfg)
    try:
        vals = req.get_values(list(PIN_MAP.values()))
        out = {}
        if isinstance(vals, dict):
            for name, pin in PIN_MAP.items():
                v = vals.get(pin, 0)
                out[name] = 1 if v == Value.ACTIVE or v == 1 else 0
        else:
            for name, v in zip(PIN_MAP.keys(), vals):
                out[name] = 1 if v == Value.ACTIVE or v == 1 else 0
        return out
    finally:
        try:
            req.release()
        except Exception:
            pass

def build_client() -> mqtt.Client:
    cli = mqtt.Client(client_id=f"{DEVICE_ID}-collector", protocol=mqtt.MQTTv311)
    cli.on_connect = on_connect
    cli.on_disconnect = on_disconnect
    return cli

def main():
    client = build_client()
    while not stop.is_set():
        try:
            client.connect(BROKER_HOST, BROKER_PORT, keepalive=30)
            break
        except Exception as e:
            print(f"[mqtt] connect failed: {e}; retrying...")
            time.sleep(2)

    client.loop_start()
    try:
        while not stop.is_set():
            publish(client, "heartbeat/alive", True, retain=True)
            t = get_cpu_temp_c()
            if t is not None:
                publish(client, "sys/cpu_temp_c", t)
            publish(client, "sys/load1", os.getloadavg()[0])
            up = time.time() - psutil.boot_time()
            publish(client, "sys/uptime_s", up)
            publish(client, "sys/uptime_dhms", format_dhms(up))
            try:
                vals = read_gpio_snapshot()
                for name, val in vals.items():
                    publish(client, f"gpio/{name}", val)
            except Exception as e:
                print(f"[gpio] read error: {e}")
            time.sleep(INTERVAL)
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        client.loop_stop()
        client.disconnect()

if __name__ == "__main__":
    main()
