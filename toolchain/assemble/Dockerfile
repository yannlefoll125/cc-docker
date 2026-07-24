FROM python:3.12-slim

RUN pip install --no-cache-dir pyyaml jsonschema

COPY assemble.py /assemble.py
COPY module.schema.json /module.schema.json

ENTRYPOINT ["python3", "/assemble.py"]
