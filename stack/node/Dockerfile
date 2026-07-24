FROM base

# Relocatable Node.js (band 2): the official tarball unpacks into a single
# self-contained dir, so the assembled final can COPY --from it. corepack (bundled
# with node) is enabled here (yarn primed; the pnpm shim is present for runtime) so
# the package-manager shims travel inside the copied dir; COREPACK_HOME is made
# world-writable so the mapped host user can `corepack prepare` at runtime (the
# container never runs as root). pnpm@latest is intentionally not pre-primed — its
# newest major outpaces node 20; runtime `corepack prepare pnpm@<compatible>` works.
ARG NODE_MAJOR=20
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) node_arch=x64 ;; \
      arm64) node_arch=arm64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    base_url="https://nodejs.org/dist/latest-v${NODE_MAJOR}.x"; \
    file="$(curl -fsSL "$base_url/" | grep -oE "node-v${NODE_MAJOR}\.[0-9.]+-linux-${node_arch}\.tar\.gz" | head -1)"; \
    test -n "$file"; \
    mkdir -p /usr/local/node; \
    curl -fsSL "$base_url/$file" | tar -xz -C /usr/local/node --strip-components=1; \
    export PATH="/usr/local/node/bin:$PATH" COREPACK_HOME=/usr/local/node/corepack; \
    corepack enable; \
    corepack prepare yarn@stable --activate; \
    chmod -R a+rwX "$COREPACK_HOME"; \
    node --version; yarn --version
