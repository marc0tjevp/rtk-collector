import json
import os
import socket
import time
import psutil
from threading import Event
import paho.mqtt.client as mqtt

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
    payload = {"ts": int(time.time()*1000), "value": value}
    client.publish(topic(path), json.dumps(payload), qos=1, retain=retain)


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
            # heartbeat (retained)
            publish(client, "heartbeat/alive", True, retain=True)

            # sys metrics
            publish(client, "sys/cpu_temp_c", psutil.sensors_temperatures().get(
                "cpu-thermal", [{"current": 0}])[0]["current"])
            publish(client, "sys/load1", os.getloadavg()[0])
            publish(client, "sys/uptime_s", time.time() - psutil.boot_time())

            time.sleep(INTERVAL)
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        client.loop_stop()
        client.disconnect()


if __name__ == "__main__":
    main()
