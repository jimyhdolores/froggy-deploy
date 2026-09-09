#!/usr/bin/env bash

# Fix CRLF (Windows -> Linux) en todos los archivos del proyecto
if command -v sed &> /dev/null; then
    sed -i 's/\r$//' "$0" 2>/dev/null
    for f in "$(dirname "$0")"/postgres/init/*; do
        [ -f "$f" ] && sed -i 's/\r$//' "$f" 2>/dev/null
    done
    for f in "$(dirname "$0")"/deploy-*.sh; do
        [ -f "$f" ] && sed -i 's/\r$//' "$f" 2>/dev/null
    done
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== deploy-traefik ==="
echo ""

if ! command -v docker &> /dev/null; then
    echo "ERROR: Docker no esta instalado."
    exit 1
fi

if ! docker compose version &> /dev/null; then
    echo "ERROR: Docker Compose plugin no esta instalado."
    exit 1
fi

ACME_FILE="$SCRIPT_DIR/acme.json"
if [ ! -f "$ACME_FILE" ]; then
    touch "$ACME_FILE"
    chmod 600 "$ACME_FILE"
    echo "[OK] acme.json creado con permisos 600"
else
    PERMS=$(stat -c "%a" "$ACME_FILE" 2>/dev/null || stat -f "%Lp" "$ACME_FILE" 2>/dev/null)
    if [ "$PERMS" != "600" ]; then
        chmod 600 "$ACME_FILE"
        echo "[OK] acme.json: permisos corregidos a 600"
    else
        echo "[OK] acme.json con permisos correctos"
    fi
fi

echo "[*] Reiniciando Traefik..."
docker compose -f "$SCRIPT_DIR/docker-compose.yml" down
docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d
echo "[OK] Traefik levantado"
echo ""

docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "NAMES|traefik"
