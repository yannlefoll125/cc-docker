FROM python:3.12-slim

RUN pip install --no-cache-dir pyyaml jsonschema

COPY generate-compose.py /generate-compose.py
COPY cc-docker.schema.json /cc-docker.schema.json

ENTRYPOINT ["python3", "/generate-compose.py"]
