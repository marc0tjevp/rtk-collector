# rtk-collector 

## Run locally
```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
export MQTT_HOST=localhost MQTT_PORT=1883 DEVICE_ID=isg-502-01 BASE_TOPIC=rtk INTERVAL_SEC=5
python -m rtk_collector.main
