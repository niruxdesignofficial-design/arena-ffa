# Servidor dedicado de ARENA FFA (Godot headless + WebSocket :8910)
FROM ubuntu:24.04

ARG GODOT_VERSION=4.4.1
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl unzip libfontconfig1 \
    && rm -rf /var/lib/apt/lists/*

RUN curl -sL -o /tmp/godot.zip \
        "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip" \
    && unzip /tmp/godot.zip -d /usr/local/bin/ \
    && mv /usr/local/bin/Godot_v${GODOT_VERSION}-stable_linux.x86_64 /usr/local/bin/godot \
    && chmod +x /usr/local/bin/godot \
    && rm /tmp/godot.zip

WORKDIR /app
COPY . /app

# Importar assets una vez en build (evita el import en cada arranque).
RUN godot --headless --import || true

EXPOSE 8910
CMD ["godot", "--headless", "--", "server"]
