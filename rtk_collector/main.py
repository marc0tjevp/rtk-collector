import json
import os
import socket
import time
import glob
import psutil
from threading import Event
import paho.mqtt.client as mqtt
from typing import Optional


BROKER_HOST = os.getenv("MQTT_HOST", "localhost")
BROKER_PORT = int(os.getenv("MQTT_PORT", "1883"))
DEVICE_ID = os.getenv("DEVICE_ID", socket.gethostname())
BASE_TOPIC = os.getenv("BASE_TOPIC", "rtk")
INTERVAL = int(os.getenv("INTERVAL_SEC", "5"))

stop = Event()


def topic(path: str) -> str:
    return f"{BASE_TOPIC}/{DEVICE_ID}/{path}"


def on_connect(client, userdata, flags, rc, properties=None):
    print(f"[mqtt] connected rc={rc}")


def on_disconnect(client, userdata, rc, properties=None):
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
    # 1) try psutil first
    try:
        temps = psutil.sensors_temperatures()
        for key in ("cpu-thermal", "cpu_thermal", "coretemp", "soc_thermal"):
            arr = temps.get(key)
            if arr and len(arr) and hasattr(arr[0], "current"):
                return float(arr[0].current)
    except Exception:
        pass

    # 2) thermal_zone fallback
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

    # 3) vcgencmd (Pi-specific)
    try:
        import subprocess
        out = subprocess.check_output(
            ["vcgencmd", "measure_temp"], text=True).strip()
        if "temp=" in out:
            return float(out.split("temp=")[1].split("'")[0])
    except Exception:
        pass

    return None


def main():
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2,
                         client_id=f"{DEVICE_ID}-collector")
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

            # CPU Temp
            temp = get_cpu_temp_c()
            if temp is not None:
                publish(client, "sys/cpu_temp_c", temp)

            # Load
            publish(client, "sys/load1", os.getloadavg()[0])

            # Uptime
            uptime_sec = time.time() - psutil.boot_time()
            publish(client, "sys/uptime_s", uptime_sec)
            publish(client, "sys/uptime_dhms", format_dhms(uptime_sec))

            time.sleep(INTERVAL)
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        client.loop_stop()
        client.disconnect()


if __name__ == "__main__":
    main()
