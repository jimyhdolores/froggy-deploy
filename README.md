# froggy-deploy

Infraestructura y despliegue de las apps de froggydevs en el servidor Hetzner.

Traefik como reverse proxy con HTTPS de Let's Encrypt, un PostgreSQL 17 compartido, y un
unico script `deploy.sh` que despliega cualquier app por nombre.

```bash
deploy glowpe              # backend y frontend
deploy glowpe backend      # solo un tier
deploy --all               # infraestructura y todas las apps
```

Cada despliegue actualiza el codigo (`git clone` la primera vez, `git pull` despues),
comprueba las precondiciones, construye, y **verifica que el contenedor quedo sano** antes de
reportar exito.

---

## Desplegar desde tu maquina

`deploy` es una funcion que ejecuta `deploy.sh` en el servidor por SSH. **Se instala una vez
por cada ordenador** desde el que quieras desplegar: la configuracion (el acceso SSH y la
funcion en tu shell) es local a esa maquina, no del servidor.

```bash
git clone git@github.com:jimyhdolores/froggy-deploy.git
cd froggy-deploy
bash client/install.sh --host 5.78.155.68 --key ~/.ssh/id_rsa_codeabien
```

En Windows sirve tanto desde Git Bash como desde PowerShell. Desde Git Bash, `install.sh`
configura **los dos** shells de una vez. Si no tienes Git Bash:

```powershell
powershell -ExecutionPolicy Bypass -File client\install.ps1 -ServerHost 5.78.155.68 -Key ~\.ssh\id_rsa_codeabien
```

El instalador anade un `Host froggy` a `~/.ssh/config`, define la funcion `deploy` en tu perfil
y comprueba que la conexion funciona. Es idempotente: reejecutarlo con otra `--host` o `--key`
sustituye el bloque anterior en lugar de duplicarlo. **Abre una terminal nueva** despues, para
que el perfil se cargue.

> Lo unico que el instalador no puede darte es la **clave privada**: es un secreto y no viaja
> en el repositorio. O la copias desde una maquina que ya funcione, o generas una nueva y
> autorizas su `.pub` en `~/.ssh/authorized_keys` del servidor. Si no la encuentra, el script
> te dice como hacer ambas cosas.

Sin instalar nada, el equivalente literal es:

```bash
ssh froggy 'bash ~/apps/froggy-deploy/deploy.sh glowpe'
```

Y estando dentro del servidor, `cd ~/apps/froggy-deploy && ./deploy.sh glowpe`. Las tres formas
acaban en el mismo script: las dos primeras solo ahorran teclas.

### Comandos del dia a dia

| Comando | Que hace |
|---|---|
| `deploy --list` | Lista las apps registradas, sus tiers y contenedores |
| `deploy doctor` | Comprueba el registro contra el disco del servidor. No despliega nada |
| `deploy <app>` | Despliega todos los tiers de la app |
| `deploy <app> <tier>` | Despliega solo ese tier (`backend`, `frontend`, `web`) |
| `deploy <app> --dry-run` | Ensayo: imprime lo que haria, sin clonar ni construir |
| `deploy --all` | Infraestructura y todas las apps |
| `deploy infra` | Solo PostgreSQL, Traefik y las bases |

```bash
deploy glowpe                  # glowpe entero
deploy glowpe backend          # solo su API
deploy tours frontend          # solo la web de rutealo
deploy checkout                # su unico tier: web
deploy glowpe --dry-run        # ver que haria, sin tocar nada
```

Ante la duda, `deploy doctor` primero: dice si falta algun `.env` o si un repo no esta clonado,
sin efectos secundarios.

---

## Estructura

```
froggy-deploy/
├── deploy.sh                 # punto de entrada unico
├── apps.d/                   # EL REGISTRO: un fichero por app
│   ├── barber.conf  checkout.conf  glowpe.conf  tours.conf
├── client/                   # configura TU maquina para usar el comando `deploy`
│   ├── install.sh            # bash: Git Bash, Linux, macOS
│   └── install.ps1           # PowerShell nativo
├── lib/
│   ├── common.sh             # codigos de salida, log, lock, traps
│   ├── registry.sh           # carga y validacion de apps.d/*.conf
│   ├── git.sh                # clone / fetch / fast-forward, SHA antes->despues
│   ├── docker.sh             # guardas, redes, compose, verificacion del contenedor
│   ├── db.sh                 # espera de postgres, creacion de bases, bootstrap SQL
│   └── infra.sh              # postgres + traefik + acme.json
├── docker-compose.yml        # Traefik v3.6
├── traefik.yml               # configuracion estatica de Traefik
├── postgres/docker-compose.yml   # PostgreSQL 17 compartido
├── logs/                     # un log por despliegue (los 50 mas recientes)
└── acme.json                 # certificados (lo crea deploy.sh, no versionado)
```

Los repositorios de las apps son **hermanos** de este directorio:

```
~/apps/
├── froggy-deploy/     <- este repo
├── app-tours/  app-barber/  glowpe/  froggy-checkout/
```

Esa convencion la resuelve `APPS_DIR`, que por defecto es el directorio padre de
`deploy.sh` y se puede cambiar con `--apps-dir` o `FROGGY_APPS_DIR` (util para ensayar
fuera del servidor).

---

## Referencia completa de `deploy.sh`

Todos los objetivos y opciones. Con el comando `deploy` instalado, `deploy <objetivo>` es
equivalente a `./deploy.sh <objetivo>` en el servidor.

```
./deploy.sh <objetivo> [tier...] [opciones]

Objetivos:
  <app>            todos los tiers de la app
  <app> <tier>...  solo esos tiers
  infra            PostgreSQL + Traefik + bases de datos
  traefik          solo Traefik
  postgres         solo PostgreSQL + bases de datos
  doctor           valida el registro contra el disco, sin tocar nada
  --all            infraestructura y todas las apps habilitadas
  --list           lista el registro

Opciones:
  --no-pull          no actualizar el codigo; reconstruir lo que ya esta en disco
  --no-build         recrear el contenedor sin reconstruir la imagen
  --branch <rama>    usar otra rama solo en esta ejecucion
  --bootstrap-db     ejecutar el SQL de bootstrap aunque la base ya existiera
  --wait-lock        encolarse si hay otro despliegue de la misma app en curso
  --fail-fast        en --all, abortar en el primer fallo
  --apps-dir <ruta>  raiz donde viven los repos
  --dry-run          imprime lo que haria, sin clonar, construir ni tocar la base
```

### Codigos de salida

Cada clase de fallo tiene el suyo, para que quien invoque el script sepa que paso sin leer
el texto:

| | | | |
|---|---|---|---|
| `0` ok | `2` uso | `10` entorno | `11` registro |
| `12` git | `13` falta el `.env` | `14` base de datos | `15` build |
| `16` verificacion | `17` lock | | |

---

## Apps desplegadas

| App | Tiers | Contenedores | Dominio | Base de datos |
|---|---|---|---|---|
| `tours` | backend, frontend | `tours-api`, `tours-web` | rutealo.froggydevs.com | `app_tours_db` |
| `barber` | backend, frontend | `barber-api`, `barber-web` | barberpe.froggydevs.com | `app_barber_db` |
| `glowpe` | backend, frontend | `glowpe-api`, `glowpe-web` | glowpe.froggydevs.com | `app_glowpe_db` |
| `checkout` | web | `checkout-web` | pay.froggydevs.com | — |

Cuando backend y frontend comparten dominio, el backend enruta con `PathPrefix('/api')` y
prioridad 20, y el frontend recoge el resto con prioridad 10.

---

## Como se despliega una app

`deploy.sh` hace esto por cada app, en este orden:

1. **Codigo primero.** Si el repo no esta, lo clona (con el nombre de destino que fija
   `APP_DIR`); si esta, hace `fetch` y `merge --ff-only`. Reporta `SHA antes -> despues` y
   los commits que entran.
2. **Base de datos.** Si la app declara `APP_DB`, la crea si falta. Si ademas declara
   `APP_DB_BOOTSTRAP_SQL`, lo ejecuta **solo** cuando acaba de crear la base y esta no tiene
   esquemas de usuario.
3. **Por cada tier:** comprueba el compose, el `env_file` requerido y las redes externas;
   valida el compose; construye y recrea; y verifica el contenedor.

### Cuando aborta, y por que

El script **nunca descarta trabajo**. Se detiene y explica en tres casos:

- **El arbol del servidor tiene cambios sin commitear** — los lista y sale con 12. Decide tu:
  `git stash`, `git commit` o `git reset --hard`.
- **Esta en otra rama** que la del registro — sale con 12 y ofrece las opciones (corregir
  `APP_BRANCH`, usar `--branch`, o cambiar de rama en el servidor).
- **Ha divergido de `origin`** y el fast-forward es imposible. Se usa `merge --ff-only` y no
  `git pull` a proposito: un script de despliegue no debe generar merges.

### La verificacion es real

`verify_container` sondea `docker inspect` hasta un presupuesto por tier:

- `exited` o `dead` → fallo inmediato.
- `running` + `healthy` → correcto.
- `running` + `unhealthy` → fallo.
- `running` sin healthcheck → espera una ventana de estabilidad y compara `StartedAt`: si
  cambia, es un crash-loop aunque `docker ps` diga «Up».

Al fallar imprime `RestartCount` y las ultimas 40 lineas de log del contenedor, y sale con 16.

> Hoy solo `glowpe-api` declara `HEALTHCHECK`. Para los demas, la deteccion por estabilidad
> coge crash-loops pero no un backend que arranca y sirve errores. Anadir `HEALTHCHECK` a los
> Dockerfiles de tours, barber y checkout cerraria ese hueco.

---

## Anadir una app nueva

**Crear un fichero en `apps.d/`.** Nada mas: ni tocar `deploy.sh`, ni editar otros ficheros,
ni duplicar scripts.

```bash
# apps.d/miapp.conf
APP_NAME="Mi App"
APP_REPO="git@github.com:usuario/mi-app.git"   # SSH, no HTTPS (ver abajo)
APP_DIR="mi-app"                       # nombre del directorio bajo ~/apps
APP_BRANCH="main"
APP_TIERS="backend frontend"           # tambien fija el orden de despliegue
APP_ENABLED="1"
APP_DB="mi_app_db"                     # vacio si no usa base de datos
APP_DB_BOOTSTRAP_SQL=""                # opcional, relativo a la raiz del repo

TIER_backend_COMPOSE="infra/backend/docker-compose.yml"
TIER_backend_CONTAINER="miapp-api"
TIER_backend_ENV_FILE="apps/backend/.env"
TIER_backend_WAIT="90"

TIER_frontend_COMPOSE="infra/frontend/docker-compose.yml"
TIER_frontend_CONTAINER="miapp-web"
TIER_frontend_ENV_FILE=""
TIER_frontend_WAIT="45"
```

`TIER_*_COMPOSE` es la ruta **completa** relativa a la raiz del repo, asi que una app puede
tener su compose donde quiera: `checkout` lo tiene en `infra/` sin subnivel de tier y no
necesita ningun caso especial.

**`APP_REPO` va con URL SSH (`git@github.com:...`), no HTTPS.** El servidor autentica contra
GitHub con su propia clave (`~/.ssh/root-jimy`); con HTTPS, un repositorio privado pediria
credenciales por consola y el clone se colgaria en mitad del despliegue, sin terminal donde
responder. Comprobar que la clave del servidor tiene acceso al repo nuevo:

```bash
ssh -T git@github.com          # debe saludar por el usuario correcto
```

Del lado de la app hacen falta, ademas:

1. Labels de Traefik en su `docker-compose.yml`, con `proxy-network` declarada `external`
   (y `postgres-network` si usa base de datos) y un router de nombre unico.
2. El subdominio apuntando por DNS a la IP del servidor.
3. El `.env` de produccion copiado al servidor, si su compose lo referencia por `env_file`
   (no viaja por git).

Comprobar que todo cuadra antes de desplegar:

```bash
./deploy.sh doctor
```

---

## Puesta en marcha de un servidor nuevo

```bash
# 1. Docker
curl -fsSL https://get.docker.com | sh

# 2. Rotacion de logs (obligatorio: sin esto los logs de Docker crecen sin limite)
cat >/etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "5", "compress": "true" }
}
JSON
systemctl restart docker

# 3. Este repo, y las apps como hermanas suyas
mkdir -p ~/apps && cd ~/apps
git clone https://github.com/jimyhdolores/froggy-deploy.git

# 4. DNS: cada subdominio con un registro A hacia la IP del servidor

# 5. Todo de una vez (clona las apps que falten)
cd ~/apps/froggy-deploy && ./deploy.sh --all
```

El servidor clona las apps por SSH, asi que necesita una clave propia autorizada en GitHub:

```bash
ssh-keygen -t ed25519 -C "froggy-deploy@servidor"   # y anadir la .pub a GitHub
ssh -T git@github.com                                # debe saludar por el usuario correcto
```

Por ultimo, desde tu maquina, para poder desplegar sin entrar al servidor:

```bash
bash client/install.sh --host <IP> --key ~/.ssh/<tu-clave>
```

Los `.env` de produccion no estan en git: hay que copiarlos al servidor antes del primer
despliegue de cada backend. `deploy.sh` se detiene con el codigo 13 y dice cual falta.

> Las bases de datos las crea `deploy.sh` a partir del registro. Un `docker compose up` del
> postgres a pelo ya no las crea: antes lo hacia un `init/01-create-databases.sql` que era una
> segunda fuente de verdad y se desincronizaba del resto.

---

## Comandos utiles

```bash
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
docker logs -f glowpe-api
docker inspect --format '{{.State.Health.Status}}' glowpe-api

# Bases del postgres compartido
docker exec postgres_shared psql -U postgres -c "\l"

# Salud de las apps
curl -s https://glowpe.froggydevs.com/api/health
curl -s https://rutealo.froggydevs.com/api/health

# El log del ultimo despliegue
ls -t ~/apps/froggy-deploy/logs/ | head -1
```

Un alias comodo para el `~/.bashrc` del servidor:

```bash
alias dep='~/apps/froggy-deploy/deploy.sh'
```

---

## Notas

- **Redes.** `proxy-network` la crea el compose de Traefik y `postgres-network` la de
  PostgreSQL; las apps las declaran `external`. Por eso la infraestructura tiene que estar
  levantada antes que cualquier app: `./deploy.sh infra`.
- **El backend de glowpe no se escala.** Su compose lo documenta: `IdempotencyStore` guarda
  las claves de idempotencia en un `Map` de proceso, asi que una segunda replica duplicaria
  ventas y gastos. No anadir `replicas`.
- **Finales de linea.** `.gitattributes` fuerza LF en todo lo que el servidor ejecuta. Los
  scripts antiguos llevaban un preambulo `sed -i 's/\r$//'` que reescribia el propio script en
  ejecucion; se elimino, y `./deploy.sh doctor` avisa si algun fichero llega con CRLF.
- **Despliegues concurrentes.** Cada app se despliega bajo un lock; un segundo intento sale
  con 17 en vez de competir por el mismo build. Con `--wait-lock` se encola.
