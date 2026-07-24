FROM base

# Relocatable Azul Zulu JDK (band 2): download the tarball (not the apt repo, which
# scatters files) so the JDK lives in one self-contained dir the assembled final can
# COPY --from. The exact build is resolved via Azul's metadata API (latest GA of the
# major); checksum pinning is a deferred supply-chain refinement.
ARG JAVA_VERSION=21
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) azul_arch=x64 ;; \
      arm64) azul_arch=aarch64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    url="$(curl -fsSL "https://api.azul.com/metadata/v1/zulu/packages/?java_version=${JAVA_VERSION}&os=linux&arch=${azul_arch}&archive_type=tar.gz&java_package_type=jdk&javafx_bundled=false&latest=true&release_status=ga&page_size=1" \
        | grep -oE '"download_url":"[^"]+"' | head -1 | sed 's/^"download_url":"//; s/"$//')"; \
    test -n "$url"; \
    mkdir -p /usr/local/zulu; \
    curl -fsSL "$url" | tar -xz -C /usr/local/zulu --strip-components=1; \
    /usr/local/zulu/bin/java -version
