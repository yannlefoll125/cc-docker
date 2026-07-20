FROM cc-base

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install pymupdf4llm --break-system-packages && \
    printf '#!/usr/bin/env python3\nimport sys, pymupdf4llm\nprint(pymupdf4llm.to_markdown(sys.argv[1]))\n' \
    > /usr/local/bin/pdf2md && \
    chmod +x /usr/local/bin/pdf2md