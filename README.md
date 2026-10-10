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

**glowpe ya no se construye aqui.** Esta en *modo registro*: GitHub Actions construye sus imagenes,
las publica en GHCR y, en cada push a `main` con las pruebas en verde, la despliega solo. El
servidor solo descarga y arranca. Ver «Modo registro y despliegue automatico». Las demas apps
siguen construyendo en el servidor.

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
| `deploy <app> --history` | Modo registro: los ultimos despliegues, con sus commits |
| `deploy <app> --tag <commit>` | Modo registro: volver a las imagenes de ese commit |
| `deploy <app> --pause` / `--resume` | Modo registro: pausar o reanudar el despliegue automatico |

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
├── ci/
│   └── entry.sh              # comando forzado de la llave SSH del despliegue automatico
├── lib/
│   ├── common.sh             # codigos de salida, log, lock, traps
│   ├── registry.sh           # carga y validacion de apps.d/*.conf
│   ├── git.sh                # clone / fetch / fast-forward, SHA antes->despues
│   ├── docker.sh             # guardas, redes, compose, verificacion del contenedor
│   ├── image.sh              # modo registro: descarga, comprobacion previa, vuelta atras
│   ├── state.sh              # pausa del despliegue automatico e historial
│   ├── db.sh                 # espera de postgres, creacion de bases, bootstrap SQL
│   └── infra.sh              # postgres + traefik + acme.json
├── state/                    # pausa e historial de cada app (no versionado)
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

Solo en modo registro:
  --tag <commit>     desplegar las imagenes de un commit ya publicado, sin mover el checkout
  --pull-only        codigo, descarga y comprobacion previa, sin sustituir nada
  --allow-drift      desplegar aunque la comprobacion previa vea deriva de esquema
  --build-local      via de emergencia: construir en el servidor
  --pause, --resume  pausar o reanudar el despliegue automatico
  --history          los ultimos despliegues de la app
  --auto --sha <sha> el despliegue que lanza el CI (ci/entry.sh)
```

### Codigos de salida

Cada clase de fallo tiene el suyo, para que quien invoque el script sepa que paso sin leer
el texto:

| | | | |
|---|---|---|---|
| `0` ok | `2` uso | `10` entorno | `11` registro |
| `12` git | `13` falta el `.env` | `14` base de datos | `15` build |
| `16` verificacion | `17` lock | `18` retenido (esquema) | `19` imagen no disponible |
| `20` vuelta atras fallida | | | |

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

`deploy.sh` hace esto por cada app en modo build, que es el de todas salvo glowpe (para ese, ver
«Modo registro y despliegue automatico»), en este orden:

1. **Codigo primero.** Si el repo no esta, lo clona (con el nombre de destino que fija
   `APP_DIR`); si esta, hace `fetch` y `merge --ff-only`. Reporta `SHA antes -> despues` y
   los commits que entran.
2. **Base de datos.** Si la app declara `APP_DB`, la crea si falta. Si ademas declara
   `APP_DB_BOOTSTRAP_SQL`, lo ejecuta **solo** cuando acaba de crear la base y esta no tiene
   esquemas de usuario.
3. **Por cada tier:** comprueba el compose, el `env_file` requerido y las redes externas;
   comprueba que su proyecto compose sea solo suyo (ver abajo); valida el compose; construye y
   recrea; y verifica el contenedor.
4. **Recorta la cache de build**, solo si todos los tiers quedaron sanos: `docker builder prune`
   con `--max-used-space` (por defecto 10 GB, se cambia con `BUILD_CACHE_MAX`) y
   `docker image prune` de las imagenes colgantes. Un fallo aqui solo avisa: la app ya esta
   desplegada.

### La cache de build tiene tope

Cada despliegue hace `docker compose up --build`, y BuildKit guarda las capas intermedias de
cada build para acelerar el siguiente. Nada las borraba: el 2026-10-02 ocupaban **45 GB de los
75** del disco, y el panel de Hetzner no lo muestra (enseña el tamano del disco, no su uso). Con
el disco lleno PostgreSQL deja de escribir y se cae todo.

Desde entonces cada despliegue termina recortandola. `--max-used-space` conserva lo usado mas
recientemente, asi que el build siguiente sigue siendo incremental. Para medirlo a mano, sin
tocar nada:

```bash
df -h /                     # disco: usado y libre
docker buildx du | tail -4  # cache de build: total y recuperable
```

### Proyecto compose propio

Compose reconoce los contenedores de un servicio por **proyecto + servicio**, no por
`container_name`. Sin `name:` en el compose, el proyecto es el nombre de su carpeta. Hasta el
2026-10-02, glowpe, tours y barber tenian su backend en `infra/backend/` (proyecto `backend`,
servicio `api`) y su frontend en `infra/frontend/` (`frontend`, `web`). Para compose eran la misma
app: desplegar el backend de tours **borraba `glowpe-api`** y levantaba `tours-api` en su lugar, y
el despliegue terminaba en verde. Se comprobo reproduciendolo en local.

Por eso cada compose declara su proyecto en la primera linea, `<slug>-<tier>`:

```yaml
name: glowpe-backend
```

`deploy.sh` lo vigila en cada tier, **antes de construir**, en dos pasos (codigo de salida 11):

- **Ninguna otra pieza puede resolver el mismo proyecto.** Se compara con todos los tiers del
  registro, habilitados o no, y con los dos proyectos de la infraestructura (`postgres` y
  `froggy-deploy`). Sin esta comprobacion el `up` no fallaria: borraria el contenedor ajeno.
- **El contenedor que ya corre tiene que ser de ese proyecto.** No se comprueba en `--dry-run`.

**Cambiar de proyecto** -al estrenar el `name:` o al renombrarlo- se hace una vez por tier.
Compose no adopta el contenedor creado bajo el nombre anterior: el `up` fallaria por conflicto de
nombre, sin tocarlo. `deploy.sh` se detiene antes y dice los pasos; para el backend de glowpe:

```bash
./deploy.sh glowpe backend          # actualiza el codigo y se detiene con los pasos de abajo
docker compose -f ~/apps/glowpe/infra/backend/docker-compose.yml build   # el viejo sigue sirviendo
docker rm -f glowpe-api             # desde aqui, la caida: lo que tarde en arrancar
./deploy.sh glowpe backend --no-pull --no-build
```

`--no-pull` despliega exactamente lo que se acaba de construir. Con el frontend es igual
(`glowpe-web`). La imagen tambien cambia de nombre: `backend-api` pasa a `glowpe-backend-api`.
Por eso los scripts de operacion toman la imagen por su ID (`docker inspect -f '{{.Image}}' <contenedor>`).

`./deploy.sh doctor` revisa las dos condiciones de todo el registro a la vez, sin desplegar.

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

## Modo registro y despliegue automatico

Una app esta en **modo registro** si sus tiers declaran `TIER_*_IMAGE`. Hoy solo glowpe. Nada se
construye en el servidor: el `ng build` llegaba a 2,9 GB y el kernel lo mataba en un servidor de 4 GB
sin swap (2026-10-09 y 2026-10-10), y cuando fallaba a mitad dejaba el backend nuevo con el frontend
viejo.

```
push a main ─► GitHub Actions: pruebas + job `images` ─► ghcr.io/jimyhdolores/glowpe-{api,web}:<sha>
            └► job `deploy` (con todo en verde) ─ ssh, llave limitada ─► ci/entry.sh
                 └► deploy.sh glowpe --auto --sha <sha>
```

La etiqueta de cada imagen es el **SHA completo** del commit, y la imagen lo lleva tambien en su
etiqueta OCI `org.opencontainers.image.revision`: `deploy glowpe --list` dice que commit corre cada
tier. El compose declara `image: <repo>:${IMAGE_TAG:-local}` y `deploy.sh` escribe el `IMAGE_TAG`
desplegado en el `.env` de la carpeta del compose (git lo ignora), asi que un `docker compose up` a
mano levanta lo desplegado y no otra cosa.

### Que hace `deploy.sh` en modo registro

1. **Codigo.** Avanza el checkout con `--ff-only`: el compose, el `.env` y los scripts de
   migracion salen de ahi. En `--auto`, exactamente hasta el commit pedido; si el checkout ya va
   por delante, otro despliegue mas nuevo llego antes y este sale con 0 («obsoleto»).
2. **Guardas, solo en `--auto`:**
   - **Pausa** (ver abajo): sale con 0 sin tocar nada, ni el checkout.
   - **Esquema:** si entre el commit que corre y el destino cambia algo de `APP_SCHEMA_PATHS`
     (`tenant.sql`, `init-glowpe-db.sql`, `scripts/migrate-*`), sale con **18**, **retenido**: la
     ventana de migracion la lleva una persona.
   - **Que tiers:** solo los que cambiaron en sus `TIER_*_SOURCES`, que son las rutas que copia su
     Dockerfile. Un commit de documentacion o de pruebas no reinicia la API.
3. **Preparar TODOS los tiers antes de tocar nada:** las comprobaciones de siempre, la descarga y
   la **comprobacion previa**. La comprobacion previa lanza la imagen nueva del backend en un
   contenedor efimero contra la base, con `SCHEMA_CHECK_ONLY=1`: compara las entidades con el
   esquema de **todos** los tenants y sale con 3 si no encajan. Entonces `deploy.sh` sale con 18 y
   produccion sigue intacta. La imagen declara que sabe hacerlo con la etiqueta `froggy.preflight`;
   sin ella no se lanza, porque arrancaria como un backend normal, crones incluidos.
4. **Aplicar, tier a tier:** `up --no-build --pull never`, verificar, y comprobar que el contenedor
   corre la revision esperada.
5. **Vuelta atras, solo en `--auto`:** si algo falla con un tier ya sustituido, se vuelve a su
   imagen anterior (etiquetada `<repo>:rollback` justo antes), se pausa el automatico y se sale
   con 16. Si la vuelta atras tambien falla, con **20**. A mano no hay vuelta atras automatica: en
   una ventana «desplegar y luego migrar», el bucle de reinicio es lo esperado.
6. **Historial** (`--history`) y **retencion:** se conservan en local las 5 imagenes de commit mas
   recientes por repo (`IMAGE_KEEP`), mas la que corre y la de `rollback`.

`--auto` sale con 0 en los casos «obsoleto», «en pausa» y «ningun tier cambio», y lo dice con una
linea que empieza por `AUTO:`.

### Cambios de esquema

Un push que cambia el esquema queda **retenido** (18, en rojo en GitHub) y produccion no se toca.
La ventana sigue el runbook de glowpe (`docs/operaciones-datos.md`):

```bash
deploy glowpe --pull-only   # checkout e imagenes al dia, comprobacion previa informativa; pausa el automatico
# dump, y el script de migracion con --apply (como siempre)
deploy glowpe               # pasa la comprobacion previa, despliega y quita la pausa
```

Si el orden es desplegar y despues migrar (retirar columnas o tablas), `deploy glowpe --allow-drift`.

### La pausa

Detiene solo el despliegue automatico; los manuales siguen funcionando. La activan las operaciones
que dejan produccion a proposito en un estado que el siguiente push desharia:

- `--tag`
- `--pull-only`
- `--allow-drift`
- `--build-local`
- la vuelta atras automatica
- `--pause`

La quita un `deploy <app>` manual de todos los tiers que termine sano, o `--resume`. Para pausar
**todas** las apps desde GitHub sin entrar al servidor, la variable `AUTO_DEPLOY=false` del repo.

### Volver atras

```bash
deploy glowpe --history          # que corre y que corrio antes
deploy glowpe --tag 9e42929      # las imagenes de ese commit; admite el SHA corto
```

`--tag` no mueve el checkout y pausa el automatico. La comprobacion previa tambien corre: si el
esquema ya avanzo, la imagen vieja no encaja y se retiene. Volver atras entonces exige deshacer
tambien el esquema, desde el dump.

### Configuracion, una sola vez

- **Login en GHCR** (las imagenes son privadas). Un token *classic* con solo `read:packages`;
  los *fine-grained* no sirven para GHCR. En el servidor: `docker login ghcr.io -u <usuario>`.
  Cuando caduque, los despliegues saldran con 19 y lo diran.
- **La llave del CI**, en `~/.ssh/authorized_keys`, limitada a un comando:

  ```
  restrict,command="/bin/bash /root/apps/froggy-deploy/ci/entry.sh" ssh-ed25519 AAAA... github-actions
  ```

  `ci/entry.sh` solo acepta `<app> <sha de 40>` y lanza `deploy.sh --auto` desacoplado de la
  conexion: si el job de Actions se corta, el despliegue no se queda a medias.
- **En el repo de la app**, en GitHub:
  - el secreto `DEPLOY_SSH_KEY`, con la llave privada;
  - las variables `DEPLOY_HOST`, `DEPLOY_KNOWN_HOSTS` y `AUTO_DEPLOY=true`.

### Via de emergencia

Si GitHub Actions o GHCR no estan disponibles, `deploy glowpe --build-local` construye en el servidor
como antes. El Dockerfile del frontend lleva los topes de memoria que lo hacen caber. La imagen
resultante no lleva etiqueta de revision, asi que el automatico queda en pausa hasta el siguiente
`deploy glowpe` normal.

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
4. Los **volumenes externos** que declare su compose (`external: true`), creados una vez. Si
   faltan, `docker compose up` falla antes de recrear el contenedor —el viejo sigue sirviendo—
   con «external volume ... not found». Hoy solo glowpe tiene uno: `glowpe-media`, ver abajo.
5. Un **`name:` propio** en la primera linea de cada compose, `<slug>-<tier>` (ver «Proyecto
   compose propio»). Sin el, el proyecto es el nombre de la carpeta -`backend`, `frontend`,
   `infra`-, que cualquier otra app puede repetir, y `deploy.sh` se negaria a desplegar la segunda.

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

Las apps en modo registro necesitan ademas el login en GHCR y, si se despliegan solas, la llave del
CI: ver «Modo registro y despliegue automatico», «Configuracion, una sola vez».

Por ultimo, desde tu maquina, para poder desplegar sin entrar al servidor:

```bash
bash client/install.sh --host <IP> --key ~/.ssh/<tu-clave>
```

Los `.env` de produccion no estan en git: hay que copiarlos al servidor antes del primer
despliegue de cada backend. `deploy.sh` se detiene con el codigo 13 y dice cual falta.

Y los volumenes externos de las apps, tambien una sola vez. El de glowpe guarda las imagenes del
catalogo (RN-PROD-47) y su contenedor corre como `node` (uid 1000), asi que el volumen se crea y
se le da ese dueno:

```bash
docker volume create glowpe-media
docker run --rm -v glowpe-media:/data/media alpine chown 1000:1000 /data/media
```

**No esta en el `pg_dump`.** Se respalda aparte, junto con la base:
`tar czf /root/backups/glowpe-media-$(date +%F).tgz -C /var/lib/docker/volumes/glowpe-media/_data .`

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

# El log del ultimo despliegue (los del CI, ademas, en logs/ci-*.out)
ls -t ~/apps/froggy-deploy/logs/ | head -1

# Modo registro: que commit corre cada tier, y que corrio antes
./deploy.sh --list
./deploy.sh glowpe --history
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
  con 17 en vez de competir por el mismo build. Con `--wait-lock` se encola, hasta
  `LOCK_WAIT_MAX` (30 min): es lo que hace el despliegue automatico, que asi espera detras de un
  despliegue manual en curso.
