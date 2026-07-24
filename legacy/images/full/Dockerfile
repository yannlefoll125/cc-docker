FROM cc-vue3

# --- Rich CLI tooling + Python 3 + Ruby (single apt layer) ---
RUN apt-get update && apt-get install -y --no-install-recommends \
      ripgrep fd-find jq fzf bat tree vim nano less unzip zip \
      build-essential sqlite3 openssh-client procps \
      python3 python3-pip python3-venv pipx \
      ruby-full \
    && ln -sf "$(command -v fdfind)" /usr/local/bin/fd \
    && ln -sf "$(command -v batcat)" /usr/local/bin/bat \
    && gem install --no-document bundler \
    && rm -rf /var/lib/apt/lists/*

# --- GitHub CLI (gh) ---
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# --- yq (single binary from GitHub releases, arch-detected) ---
RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}" \
      -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq

# --- Zulu JDK 21 (inline, mirrors images/zulu21) ---
RUN curl -fsSL https://repos.azul.com/azul-repo.key -o /usr/share/keyrings/azul.asc \
    && echo "deb [signed-by=/usr/share/keyrings/azul.asc] https://repos.azul.com/zulu/deb stable main" > /etc/apt/sources.list.d/azul.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends zulu21-jdk \
    && rm -rf /var/lib/apt/lists/*

# --- Go (current stable tarball, arch-detected) ---
ENV GO_VERSION=1.26.5
RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz" \
      | tar -C /usr/local -xz
ENV PATH="/usr/local/go/bin:${PATH}"

# --- Rust (rustup, shared system toolchain writable by any mapped user) ---
ENV RUSTUP_HOME=/opt/rust/rustup CARGO_HOME=/opt/rust/cargo
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal \
    && chmod -R a+rwX /opt/rust
ENV PATH="/opt/rust/cargo/bin:${PATH}"

# --- pdf2md command (mirrors images/pdf2md) ---
RUN pip3 install pymupdf4llm --break-system-packages && \
    printf '#!/usr/bin/env python3\nimport sys, pymupdf4llm\nprint(pymupdf4llm.to_markdown(sys.argv[1]))\n' \
    > /usr/local/bin/pdf2md && \
    chmod +x /usr/local/bin/pdf2md
