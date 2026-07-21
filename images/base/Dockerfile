FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    git \
    gosu \
    make \
    wl-clipboard \
    xclip \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://claude.ai/install.sh | bash
RUN cp -L /root/.local/bin/claude /usr/local/bin/claude

#ENV PATH="/root/.local/bin:$PATH"

COPY cc-wrapper.sh /cc-wrapper.sh
RUN chmod +x /cc-wrapper.sh

COPY run-as-hostuser.sh /run-as-hostuser.sh
RUN chmod +x /run-as-hostuser.sh

COPY sandbox.md /sandbox.md


ENTRYPOINT ["/cc-wrapper.sh"]