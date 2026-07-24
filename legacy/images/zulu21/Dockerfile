FROM cc-base

RUN curl -fsSL https://repos.azul.com/azul-repo.key -o /usr/share/keyrings/azul.asc \
    && echo "deb [signed-by=/usr/share/keyrings/azul.asc] https://repos.azul.com/zulu/deb stable main" > /etc/apt/sources.list.d/azul.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends zulu21-jdk \
    && rm -rf /var/lib/apt/lists/*
