FROM base

RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        docker-ce-cli docker-compose-plugin python3 python3-yaml python3-jsonschema \
    && rm -rf /var/lib/apt/lists/*

COPY toolchain/dev/dev-wrapper.sh /dev-wrapper.sh
RUN chmod +x /dev-wrapper.sh

# Shadow docker-ce-cli's /usr/bin/docker with a shim (/usr/local/bin precedes
# /usr/bin on PATH) that tags every container/image this image creates on the
# host daemon, so they can be told apart from ones started natively. See
# docker-shim.sh for details. COMPOSE_PROJECT_NAME covers `docker compose`.
COPY toolchain/dev/docker-shim.sh /usr/local/bin/docker
RUN chmod +x /usr/local/bin/docker
ENV COMPOSE_PROJECT_NAME=cc-dev

# cc-dev's entrypoint chain hands off to the same bootstrap/ scripts every
# assembled final gets (dev-wrapper.sh -> cc-wrapper.sh -> run-as-hostuser.sh),
# so it needs its own copy — `build.sh` builds this image with the repo root
# as context (not just toolchain/dev/) to reach them.
COPY bootstrap/cc-wrapper.sh /cc-wrapper.sh
COPY bootstrap/run-as-hostuser.sh /run-as-hostuser.sh
COPY bootstrap/sandbox.md /sandbox.md
RUN chmod +x /cc-wrapper.sh /run-as-hostuser.sh

ENTRYPOINT ["/dev-wrapper.sh"]
