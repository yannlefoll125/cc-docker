FROM base

# Relocatable CPython (band 2): python-build-standalone ships a portable interpreter
# that unpacks into a single self-contained dir, so the assembled final can
# COPY --from it — the same model as stack/node. The apt-installed system python
# would scatter files across /usr and can't be COPY'd as one artifact. pip is
# bundled (install_only flavor), so `pip install --user` works at runtime.
# The exact patch/build is resolved from the project's latest GitHub release (grep
# the matching install_only asset); checksum pinning is a deferred refinement.
ARG PYTHON_VERSION=3.12
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) pbs_arch=x86_64 ;; \
      arm64) pbs_arch=aarch64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    url="$(curl -fsSL https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest \
        | grep -oE '"browser_download_url": *"[^"]+"' \
        | sed -E 's/^"browser_download_url": *"//; s/"$//' \
        | grep -E "cpython-${PYTHON_VERSION}\.[0-9]+(%2B|\+)[0-9]+-${pbs_arch}-unknown-linux-gnu-install_only\.tar\.gz$" \
        | head -1)"; \
    test -n "$url"; \
    mkdir -p /usr/local/python; \
    curl -fsSL "$url" | tar -xz -C /usr/local/python --strip-components=1; \
    /usr/local/python/bin/python3 --version; \
    /usr/local/python/bin/pip3 --version
