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

echo "=== froggy-deploy: setup inicial ==="
echo ""

# 1. Verificar que Docker este instalado
if ! command -v docker &> /dev/null; then
    echo "ERROR: Docker no esta instalado."
    echo "Instalar con: curl -fsSL https://get.docker.com | sh"
    exit 1
fi

if ! docker compose version &> /dev/null; then
    echo "ERROR: Docker Compose plugin no esta instalado."
    exit 1
fi

echo "[OK] Docker $(docker --version | cut -d' ' -f3)"
echo "[OK] $(docker compose version)"
echo ""

# 2. Levantar PostgreSQL
echo "[*] Levantando PostgreSQL..."
docker compose -f "$SCRIPT_DIR/postgres/docker-compose.yml" up -d
echo ""

# 3. Esperar a que PostgreSQL este listo
echo "[*] Esperando a que PostgreSQL acepte conexiones..."
RETRIES=30
until docker exec postgres_shared pg_isready -U postgres > /dev/null 2>&1; do
    RETRIES=$((RETRIES - 1))
    if [ "$RETRIES" -le 0 ]; then
        echo "ERROR: PostgreSQL no respondio despues de 30 intentos."
        echo "Revisar logs: docker logs postgres_shared"
        exit 1
    fi
    sleep 2
done
echo "[OK] PostgreSQL listo"
echo ""

# 4. Crear bases de datos si no existen
echo "[*] Verificando bases de datos..."
for DB_NAME in app_tours_db app_barber_db glowpe_db; do
    EXISTS=$(docker exec postgres_shared psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" 2>/dev/null)
    if [ "$EXISTS" != "1" ]; then
        docker exec postgres_shared psql -U postgres -c "CREATE DATABASE $DB_NAME;" > /dev/null 2>&1
        echo "[OK] Base de datos '$DB_NAME' creada"
    else
        echo "[OK] Base de datos '$DB_NAME' ya existe"
    fi
done
echo ""

# 5. Levantar Traefik
echo "[*] Levantando Traefik..."
bash "$SCRIPT_DIR/deploy-traefik.sh"
echo ""

# 6. Levantar app-tours backend
echo "[*] Levantando app-tours backend..."
bash "$SCRIPT_DIR/deploy-tours-backend.sh"
echo ""

# 7. Levantar app-tours frontend
echo "[*] Levantando app-tours frontend..."
bash "$SCRIPT_DIR/deploy-tours-frontend.sh"
echo ""

# 8. Levantar BarberPe backend (monorepo app-barber)
echo "[*] Levantando BarberPe backend..."
bash "$SCRIPT_DIR/deploy-barber-backend.sh"
echo ""

# 9. Levantar BarberPe frontend (monorepo app-barber)
echo "[*] Levantando BarberPe frontend..."
bash "$SCRIPT_DIR/deploy-barber-frontend.sh"
echo ""

# 10. Levantar Glowpe backend
echo "[*] Levantando Glowpe backend..."
bash "$SCRIPT_DIR/deploy-glowpe-backend.sh"
echo ""

# 11. Levantar Glowpe frontend
echo "[*] Levantando Glowpe frontend..."
bash "$SCRIPT_DIR/deploy-glowpe-frontend.sh"
echo ""

# 12. Resumen
echo "=== Setup completado ==="
echo ""
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
