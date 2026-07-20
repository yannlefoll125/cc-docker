FROM cc-base

RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        docker-ce-cli docker-compose-plugin python3 python3-yaml python3-jsonschema \
    && rm -rf /var/lib/apt/lists/*

COPY dev-wrapper.sh /dev-wrapper.sh
RUN chmod +x /dev-wrapper.sh

# Shadow docker-ce-cli's /usr/bin/docker with a shim (/usr/local/bin precedes
# /usr/bin on PATH) that tags every container/image this image creates on the
# host daemon, so they can be told apart from ones started natively. See
# docker-shim.sh for details. COMPOSE_PROJECT_NAME covers `docker compose`.
COPY docker-shim.sh /usr/local/bin/docker
RUN chmod +x /usr/local/bin/docker
ENV COMPOSE_PROJECT_NAME=cc-dev

ENTRYPOINT ["/dev-wrapper.sh"]
