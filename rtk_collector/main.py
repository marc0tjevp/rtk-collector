import json
import os
import socket
import time
import glob
import psutil
from threading import Event
import paho.mqtt.client as mqtt
from typing import Optional
from gpiod.line import Direction, Value  # v2 enums present on your box
import gpiod

BROKER_HOST = os.getenv("MQTT_HOST", "localhost")
BROKER_PORT = int(os.getenv("MQTT_PORT", "1883"))
DEVICE_ID = os.getenv("DEVICE_ID", socket.gethostname())
BASE_TOPIC = os.getenv("BASE_TOPIC", "rtk")
INTERVAL = int(os.getenv("INTERVAL_SEC", "5"))

# Fixed Rocktech pins
PIN_IO0 = int(os.getenv("IO0_PIN", "17"))
PIN_IO1 = int(os.getenv("IO1_PIN", "18"))
PIN_IO2 = int(os.getenv("IO2_PIN", "27"))
PIN_IO3 = int(os.getenv("IO3_PIN", "22"))
PIN_MAP = {"IO0": PIN_IO0, "IO1": PIN_IO1, "IO2": PIN_IO2, "IO3": PIN_IO3}

stop = Event()

def topic(path: str) -> str:
    return f"{BASE_TOPIC}/{DEVICE_ID}/{path}"

# Accept extra args to avoid callback signature issues
def on_connect(client, userdata, flags, rc, properties=None, *extra):
    print(f"[mqtt] connected rc={rc}")

def on_disconnect(client, userdata, rc, properties=None, *extra):
    print(f"[mqtt] disconnected rc={rc}")

def publish(client, path, value, retain=False):
    payload = {"ts": int(time.time() * 1000), "value": value}
    client.publish(topic(path), json.dumps(payload), qos=1, retain=retain)

def format_dhms(seconds: float) -> str:
    secs = int(seconds)
    d, r = divmod(secs, 86400)
    h, r = divmod(r, 3600)
    m, s = divmod(r, 60)
    return f"{d}d {h}h {m}m {s}s"

def get_cpu_temp_c() -> Optional[float]:
    # 1) psutil
    try:
        temps = psutil.sensors_temperatures()
        for key in ("cpu-thermal", "cpu_thermal", "coretemp", "soc_thermal"):
            arr = temps.get(key)
            if arr and len(arr) and hasattr(arr[0], "current"):
                return float(arr[0].current)
    except Exception:
        pass
    # 2) thermal zones
    try:
        for zone in glob.glob("/sys/class/thermal/thermal_zone*"):
            tfile = os.path.join(zone, "temp")
            if os.path.exists(tfile):
                with open(tfile) as f:
                    raw = f.read().strip()
                val = float(raw)
                return val / 1000.0 if val > 200 else val
    except Exception:
        pass
    # 3) vcgencmd
    try:
        import subprocess
        out = subprocess.check_output(["vcgencmd", "measure_temp"], text=True).strip()
        if "temp=" in out:
            return float(out.split("temp=")[1].split("'")[0])
    except Exception:
        pass
    return None

def read_gpio_snapshot() -> dict:
    """
    Non-invasive read: request lines AS_IS, read once, release immediately.
    Does not change direction/level and does not keep pins busy.
    """
    cfg = {pin: gpiod.LineSettings(direction=Direction.AS_IS) for pin in PIN_MAP.values()}
    req = gpiod.request_lines(
        "/dev/gpiochip0",
        consumer="rtk-collector",
        config=cfg,
    )
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

def main():
    client = mqtt.Client(protocol=mqtt.MQTTv5, client_id=f"{DEVICE_ID}-collector")
    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    client.reconnect_delay_set(min_delay=1, max_delay=30)

    # connect loop
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
            # Heartbeat (retained)
            publish(client, "heartbeat/alive", True, retain=True)

            # Sys metrics
            temp = get_cpu_temp_c()
            if temp is not None:
                publish(client, "sys/cpu_temp_c", temp)
            publish(client, "sys/load1", os.getloadavg()[0])
            uptime_sec = time.time() - psutil.boot_time()
            publish(client, "sys/uptime_s", uptime_sec)
            publish(client, "sys/uptime_dhms", format_dhms(uptime_sec))

            # GPIO read-only snapshot (non-blocking)
            try:
                vals = read_gpio_snapshot()
                for name, val in vals.items():
                    publish(client, f"gpio/{name}", val)
            except Exception as e:
                # Log once per loop, but don't crash the agent
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
