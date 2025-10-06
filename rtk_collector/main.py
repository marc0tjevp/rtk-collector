import json
import os
import socket
import time
from threading import Event
import paho.mqtt.client as mqtt

# env with sane fallbacks
BROKER_HOST = os.getenv("MQTT_HOST", "localhost")
BROKER_PORT = int(os.getenv("MQTT_PORT", "1883"))
DEVICE_ID = os.getenv("DEVICE_ID", socket.gethostname())
BASE_TOPIC = os.getenv("BASE_TOPIC", "rtk")
INTERVAL = int(os.getenv("INTERVAL_SEC", "5"))

TOPIC = f"{BASE_TOPIC}/{DEVICE_ID}/heartbeat/alive"
stop = Event()


def on_connect(client, userdata, flags, rc, properties=None):
    print(f"[mqtt] connected rc={rc}")


def on_disconnect(client, userdata, rc, properties=None):
    print(f"[mqtt] disconnected rc={rc}")


def main():
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2,
                         client_id=f"{DEVICE_ID}-collector")
    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    client.reconnect_delay_set(min_delay=1, max_delay=30)

    # connect loop (non-fatal if broker not up yet)
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
            payload = {"ts": int(time.time()*1000), "value": True}
            client.publish(TOPIC, json.dumps(payload), qos=1, retain=True)
            time.sleep(INTERVAL)
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        client.loop_stop()
        client.disconnect()


if __name__ == "__main__":
    main()
