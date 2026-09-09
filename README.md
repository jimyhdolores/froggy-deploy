# froggy-deploy

Infraestructura compartida para el servidor Hetzner. Contiene el reverse proxy (Traefik) y la base de datos (PostgreSQL) que usan todas las aplicaciones de `froggydevs.com`.

## Estructura

```
froggy-deploy/
├── setup.sh                            # Setup inicial (PostgreSQL + Traefik + apps)
├── deploy-traefik.sh                   # Reiniciar Traefik independientemente
├── deploy-tours-backend.sh             # Rebuild y deploy del backend de app-tours
├── deploy-tours-frontend.sh            # Rebuild y deploy del frontend web de app-tours
├── deploy-glowpe-backend.sh            # Rebuild y deploy del backend de glowpe
├── deploy-glowpe-frontend.sh           # Rebuild y deploy del frontend de glowpe
├── docker-compose.yml                  # Traefik (reverse proxy)
├── traefik.yml                         # Configuracion estatica de Traefik
├── acme.json                           # Certificados SSL (se crea automaticamente, no se versiona)
└── postgres/
    ├── docker-compose.yml              # PostgreSQL 17 compartido
    └── init/
        └── 01-create-databases.sql     # Crea app_barber_db, app_tours_db y glowpe_db al iniciar por primera vez
```

## Que hace cada componente

### Traefik

Reverse proxy que recibe todo el trafico HTTP/HTTPS del servidor y lo enruta a los contenedores correctos segun subdominio y path:

| Subdominio                | Path     | Contenedor destino | Puerto interno | Priority |
| ------------------------- | -------- | ------------------ | -------------- | -------- |
| `rutealo.froggydevs.com`  | `/api/*` | tours-api          | 3000           | 20       |
| `rutealo.froggydevs.com`  | `/*`     | tours-web          | 80             | 10       |
| `barberpe.froggydevs.com` | `/*`     | barber-api         | 3000           | —        |
| `glowpe.froggydevs.com`  | `/api/*` | glowpe-api         | 3000           | 20       |
| `glowpe.froggydevs.com`  | `/*`     | glowpe-web         | 80             | 10       |
| `pay.froggydevs.com`      | `/*`     | checkout-web       | 80             | —        |

- Redirige automaticamente HTTP a HTTPS.
- Genera y renueva certificados SSL via Let's Encrypt.
- Descubre servicios automaticamente por labels de Docker (`exposedByDefault: false` — solo expone contenedores que declaren labels explicitamente).
- Para `rutealo.froggydevs.com`, usa routing por path: `/api` va al backend (NestJS), todo lo demas va al frontend (Nginx).

### PostgreSQL

Instancia unica de PostgreSQL 17 accesible solo por red interna Docker (`postgres-network`). No expone puertos al host.

El init script crea las bases de datos la primera vez que el volumen se inicializa:

- `app_barber_db`
- `app_tours_db`
- `glowpe_db`

## Redes Docker

Traefik y PostgreSQL crean dos redes que los demas proyectos referencian como `external: true`:

| Red                | Proposito                      | Quien la crea                  | Quien se conecta                               |
| ------------------ | ------------------------------ | ------------------------------ | ---------------------------------------------- |
| `proxy-network`    | Traefik ↔ contenedores de apps | `docker-compose.yml` (Traefik) | barber-api, tours-api, tours-web, glowpe-api, glowpe-web, checkout-web |
| `postgres-network` | Apps ↔ PostgreSQL              | `postgres/docker-compose.yml`  | barber-api, tours-api, glowpe-api                                      |

## Como la usan los proyectos

Cada proyecto declara las redes como externas en su `docker-compose.yml` y agrega labels Traefik para que el proxy lo descubra:

```yaml
# Ejemplo (BarberPe, monorepo app-barber): infra/backend/docker-compose.yml
networks:
  proxy-network:
    external: true
  postgres-network:
    external: true

services:
  api:
    build: ...
    labels:
      - 'traefik.enable=true'
      - 'traefik.http.routers.barber.rule=Host(`barberpe.froggydevs.com`)'
      - 'traefik.http.routers.barber.entrypoints=websecure'
      - 'traefik.http.routers.barber.tls.certresolver=letsencrypt'
      - 'traefik.http.services.barber.loadbalancer.server.port=3000'
    networks:
      - proxy-network
      - postgres-network
```

Para proyectos que comparten dominio con routing por path (como app-tours), se usa `PathPrefix` y `priority`:

```yaml
# Backend: captura /api con priority alta
labels:
  - 'traefik.http.routers.tours.rule=Host(`rutealo.froggydevs.com`) && PathPrefix(`/api`)'
  - 'traefik.http.routers.tours.priority=20'

# Frontend: catch-all con priority baja
labels:
  - 'traefik.http.routers.tours-web.rule=Host(`rutealo.froggydevs.com`)'
  - 'traefik.http.routers.tours-web.priority=10'
```

Para conectarse a PostgreSQL desde el backend, el `.env` de cada app usa:

```
POSTGRES_HOST=postgres_shared
PGPORT=5432
```

## Scripts de despliegue

### `setup.sh` — Setup inicial (primera vez)

Ejecuta todo el stack en orden:

1. Convierte CRLF a LF en todos los scripts (compatibilidad Windows → Linux)
2. Verifica que Docker este instalado
3. Levanta PostgreSQL y espera a que acepte conexiones
4. Crea bases de datos si no existen
5. Ejecuta `deploy-traefik.sh`
6. Ejecuta `deploy-tours-backend.sh`
7. Ejecuta `deploy-tours-frontend.sh`

```bash
cd ~/apps/froggy-deploy
bash setup.sh
```

### `deploy-traefik.sh` — Reiniciar Traefik

Hace `down` + `up` de Traefik. Verifica y crea `acme.json` con permisos 600 si no existe.

```bash
bash deploy-traefik.sh
```

### `deploy-tours-backend.sh` — Rebuild backend

Ejecuta `docker compose up -d --build --force-recreate` para el backend NestJS de app-tours.

```bash
bash deploy-tours-backend.sh
```

### `deploy-tours-frontend.sh` — Rebuild frontend web

Ejecuta `docker compose up -d --build --force-recreate` para el frontend web de app-tours (Nginx + Angular).

```bash
bash deploy-tours-frontend.sh
```

## Setup en servidor (primera vez)

### 1. Prerequisitos

Docker y Docker Compose deben estar instalados en el servidor:

```bash
curl -fsSL https://get.docker.com | sh
```

Verificar:

```bash
docker --version
docker compose version
```

### 2. DNS

Apuntar los subdominios a la IP del servidor desde el panel del registrador de dominio (ej. Namecheap):

```
barberpe.froggydevs.com     →  A Record  →  IP_HETZNER
rutealo.froggydevs.com  →  A Record  →  IP_HETZNER
glowpe.froggydevs.com      →  A Record  →  IP_HETZNER
pay.froggydevs.com        →  A Record  →  IP_HETZNER
```

Verificar propagacion:

```bash
dig rutealo.froggydevs.com +short
```

Debe devolver la IP del servidor.

### 3. Configurar rotacion de logs de Docker

Crear `/etc/docker/daemon.json` para evitar que los logs llenen el disco:

```bash
cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "5",
    "compress": "true"
  }
}
EOF
systemctl restart docker
```

### 4. Copiar proyecto y ejecutar setup

Copiar la carpeta `froggy-deploy` al servidor (ej. via `scp` o SFTP):

```bash
scp -r froggy-deploy/ root@IP_HETZNER:~/apps/froggy-deploy
```

Si los archivos vienen de Windows, convertir finales de linea antes de ejecutar:

```bash
sed -i 's/\r$//' ~/apps/froggy-deploy/*.sh
```

Ejecutar setup:

```bash
cd ~/apps/froggy-deploy
bash setup.sh
```

### 5. Verificar que PostgreSQL creo las bases de datos

El init script (`postgres/init/01-create-databases.sql`) crea las bases de datos automaticamente **solo la primera vez** que el volumen se inicializa. Si el volumen ya existia antes de agregar el script, las bases de datos no se crean automaticamente.

Verificar que existan:

```bash
docker exec postgres_shared psql -U postgres -c "\l"
```

Debe aparecer `app_tours_db`, `app_barber_db` y `glowpe_db`. Si alguna no existe, crearla manualmente:

```bash
docker exec postgres_shared psql -U postgres -c "CREATE DATABASE app_tours_db;"
docker exec postgres_shared psql -U postgres -c "CREATE DATABASE app_barber_db;"
docker exec postgres_shared psql -U postgres -c "CREATE DATABASE glowpe_db;"
```

### 6. Verificar infraestructura

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

Debe mostrar `traefik`, `postgres_shared`, `tours-api` y `tours-web` en estado `Up`.

```bash
docker logs traefik --tail 10
docker logs postgres_shared --tail 10
```

Sin errores en ambos.

### 7. Verificar aplicaciones

```bash
docker ps
docker logs tours-api --tail 20
docker logs tours-web --tail 20
```

Probar endpoints:

```bash
curl -s https://rutealo.froggydevs.com/api/health
curl -s https://rutealo.froggydevs.com/
```

## Contenedores

| Contenedor        | Imagen          | Puerto | Descripcion                                 |
| ----------------- | --------------- | ------ | ------------------------------------------- |
| `traefik`         | traefik:v3.6    | 80,443 | Reverse proxy + SSL                         |
| `postgres_shared` | postgres:17     | —      | Base de datos compartida                    |
| `tours-api`       | node:20 (build) | 3000   | Backend NestJS de app-tours                 |
| `tours-web`       | nginx:alpine    | 80     | Frontend Angular (web-angular) de app-tours |
| `glowpe-api`      | node:22 (build) | 3000   | Backend NestJS de glowpe                    |
| `glowpe-web`      | nginx:alpine    | 80     | Frontend Angular de glowpe                  |

## Comandos utiles

```bash
docker ps                              # contenedores corriendo
docker logs <nombre> --tail 50         # ultimos 50 logs
docker logs <nombre> -f                # follow en tiempo real
docker logs <nombre> --since 1h        # logs de la ultima hora
docker restart <nombre>                # reiniciar contenedor
docker compose up -d --build           # rebuild y deploy (desde directorio del compose)
docker system prune -af --volumes      # limpiar imagenes/contenedores sin uso (destructivo)
```

## Agregar una nueva app

1. En el `docker-compose.yml` de la nueva app, declarar `proxy-network` como externa y agregar labels Traefik con un router y Host distintos.
2. Si la app comparte dominio con otra (backend + frontend), usar `PathPrefix` y `priority` en los labels de Traefik.
3. Si necesita base de datos, declarar `postgres-network` como externa y agregar la creacion de la DB en `postgres/init/01-create-databases.sql`. Si PostgreSQL ya esta corriendo, crear la DB manualmente: `docker exec postgres_shared psql -U postgres -c "CREATE DATABASE nueva_db;"`.
4. Apuntar el nuevo subdominio a la misma IP del servidor.
5. Crear un script `deploy-<app>.sh` en `froggy-deploy/` siguiendo el patron de los existentes.
