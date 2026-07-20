FROM python:3.12-slim

RUN pip install --no-cache-dir pyyaml

COPY generate-compose.py /generate-compose.py

ENTRYPOINT ["python3", "/generate-compose.py"]
