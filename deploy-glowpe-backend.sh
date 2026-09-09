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
APPS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GLOWPE_BACKEND="$APPS_DIR/glowpe/infra/backend"

echo "=== deploy-glowpe-backend ==="
echo ""

if ! command -v docker &> /dev/null; then
    echo "ERROR: Docker no esta instalado."
    exit 1
fi

if ! docker compose version &> /dev/null; then
    echo "ERROR: Docker Compose plugin no esta instalado."
    exit 1
fi

if [ ! -f "$GLOWPE_BACKEND/docker-compose.yml" ]; then
    echo "ERROR: No se encontro $GLOWPE_BACKEND/docker-compose.yml"
    exit 1
fi

echo "[*] Rebuild y deploy de glowpe backend..."
docker compose -f "$GLOWPE_BACKEND/docker-compose.yml" up -d --build --force-recreate
echo "[OK] glowpe backend desplegado"
echo ""

docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "NAMES|glowpe-api"
