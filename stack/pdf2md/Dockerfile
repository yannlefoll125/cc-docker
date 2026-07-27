FROM base

# Self-contained pdf2md (band 2): unlike node/zulu this module packages a small
# *application*, not a bare toolchain. Modules can't depend on each other (each
# stages FROM base and is COPY'd independently), so pdf2md bundles its own
# relocatable interpreter (python-build-standalone, same source as stack/python3)
# under runtime/ and installs pymupdf4llm into it. The launcher in bin/ shebangs
# that interpreter by absolute path — valid because the artifact is COPY'd to the
# same /usr/local/pdf2md path in the final. Only bin/ goes on PATH (see module.yml),
# so the bundled python3 stays private and doesn't collide with the python3 stack.
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
    mkdir -p /usr/local/pdf2md/runtime /usr/local/pdf2md/bin; \
    curl -fsSL "$url" | tar -xz -C /usr/local/pdf2md/runtime --strip-components=1; \
    /usr/local/pdf2md/runtime/bin/pip3 install --no-cache-dir pymupdf4llm; \
    printf '#!/usr/local/pdf2md/runtime/bin/python3\nimport sys, pymupdf4llm\nprint(pymupdf4llm.to_markdown(sys.argv[1]))\n' \
      > /usr/local/pdf2md/bin/pdf2md; \
    chmod +x /usr/local/pdf2md/bin/pdf2md; \
    /usr/local/pdf2md/runtime/bin/python3 -c 'import pymupdf4llm'
