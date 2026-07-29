FROM debian:bookworm-slim

# Band 1 — foundational apt. TLS + downloader (curl, ca-certificates), git, gosu
# (host UID/GID remap at runtime), make (maintainer's in-container workflow), the
# clipboard tools backing the `display:` image-paste feature (wl-clipboard, xclip),
# and openssh-server backing the `ssh:` remote-access feature (dormant unless
# cc-wrapper.sh starts it). The image-baked host keys its postinst generates are
# deleted: they'd be identical for every user of the image, so the `ssh:` feature
# generates per-project keys at runtime instead.
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    git \
    gosu \
    make \
    openssh-server \
    wl-clipboard \
    xclip \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/ssh/ssh_host_*

# claude — universal to every image, so it lives at the end of `base`: installed
# once here and shared by every assembled final via FROM (not per-image).
RUN curl -fsSL https://claude.ai/install.sh | bash
RUN cp -L /root/.local/bin/claude /usr/local/bin/claude

# Deliberately NO bootstrap scripts and NO ENTRYPOINT here. The band-4 scripts
# (cc-wrapper.sh, run-as-hostuser.sh, sandbox.md) and the ENTRYPOINT are baked into
# the assembled *final* image, which owns them. `stack/*` modules stage FROM base.
