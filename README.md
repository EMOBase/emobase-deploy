# EMOBase species deployment

Single-species deployment: the **emobase-web** frontend plus its own
Elasticsearch and Directus. MySQL and Keycloak are shared **per server**: they
run once in this server's
[`emobase-infra`](https://github.com/EMOBase/emobase-infra) and serve the portal
and every species deployed on that server.

Genomics, JBrowse2 and BLAST are **not** run here. They come from a running
[`emobase-portal-deploy`](https://github.com/EMOBase/emobase-portal-deploy) stack. The multi-species
portal itself lives in that repository.

> **Starting from an empty server?** The complete three-repository procedure is
> in the [EMOBase deployment guide](https://github.com/EMOBase/emobase-docs/blob/main/DEPLOYMENT.md).
> Deploy the local infrastructure and the portal first, then use the quick
> start below.

## Prerequisites

- Docker Engine 24+ with Compose v2
- A running `emobase-infra` stack with its `.env`
- `python3` on the Docker host for the Keycloak helper scripts
- A running portal deployment
- A public URL (or host:port) for this species site
- A public URL for the portal, reachable from this server and from browsers

## Quick start (portal on the same server)

The infrastructure, portal and species repositories are expected side by side:

```text
emobase/
├── emobase-infra/
├── emobase-portal-deploy/
└── emobase-deploy/
```

If the local infrastructure or portal is not running yet, follow their READMEs
first.

1. Generate `.env`:

   ```bash
   ./init.sh
   ```

   The species code is required and has no default; for example, enter `Tcas`.
   The script then asks for the host port, public server address, internal
   portal URL, Directus database and Compose project prefix, showing a default
   for each. `--portal-dir` copies the portal's `PUBLIC_SERVER` into this
   stack's `PORTAL_SERVER`; when the portal checkout is named
   `../emobase-portal-deploy`, `init.sh` finds it automatically. Shared MySQL
   secrets are read from `../emobase-infra/.env`.

   To answer a question in advance, pass its flag; `--yes` accepts every
   default without prompting. For example:

   ```bash
   ./init.sh --species Tcas --public-server https://tcas.example.org
   ```

   When both stacks are on the same Docker host, set
   `--portal-internal-url http://host.docker.internal:9080` to keep
   container-to-portal traffic off the public domain.

   `init.sh` also asks which Keycloak realm this species should use:

   1. **Shared realm** — reuse the portal's realm. One team manages users for
      the portal and every species site.
   2. **Dedicated realm** — create `ibb_<species>` with its own client, users
      and `coco` administrator. Use this when different people manage each
      website.

   For non-interactive runs, pass `--keycloak-realm shared` or
   `--keycloak-realm ibb_tcas`. `init.sh` derives
   `DIRECTUS_DB_DATABASE=directus_tcas`; use `--directus-db` to override it.

   A shared realm is created on demand with the first site origin. If this
   server has no portal, create it with the species origin after infra is
   healthy:

   ```bash
   ../emobase-infra/scripts/ensure-shared-realm.sh https://tcas.example.org
   ```

   `emobase species setup` and `emobase bootstrap` do this automatically.

2. Create the Directus database:

   ```bash
   ../emobase-infra/scripts/create-database.sh directus_tcas
   ```

   If you chose the shared realm, register this site's origin (this also
   creates the realm when it does not exist):

   ```bash
   ../emobase-infra/scripts/ensure-shared-realm.sh https://tcas.example.org
   ```

   `ensure-shared-realm.sh` is idempotent and also adds the origin. For an
   additional shared-realm site, `allow-origin.sh` adds only its origin. A
   dedicated realm was already created and configured by `init.sh`.

3. Initialise Directus, then start the stack:

   ```bash
   docker compose run --rm setup-directus
   docker compose up -d --wait
   ```

4. Open `${PUBLIC_SERVER}` and sign in with `COCO_USERNAME` /
   `COCO_PASSWORD` from this stack's `.env`. The password is temporary;
   Keycloak asks for a new one on first login. For a shared realm the
   credentials are the ones from `../emobase-infra/.env`; for a dedicated realm
   they belong only to this species.

### Local trial (no domain)

Start `emobase-infra` and the portal locally first. Then start the species
stack:

```bash
./init.sh --local --species Tcas
../emobase-infra/scripts/create-database.sh directus_tcas
# Only for the shared realm; a dedicated realm is configured by init.sh.
../emobase-infra/scripts/ensure-shared-realm.sh http://localhost:9090
docker compose run --rm setup-directus
docker compose up -d --wait
```

`--local` uses `localhost` for the browser URLs and sets the internal URLs
needed by the containers. Open the URL printed by `init.sh`.

The species nginx uses `PORTAL_INTERNAL_URL` for BLAST, and SSR calls use
`INTERNAL_API_*`, `INTERNAL_KEYCLOAK_ISSUER` and `INTERNAL_DIRECTUS_URL`.
`INTERNAL_KEYCLOAK_ISSUER` points at this server's Keycloak, not at the portal.
The browser also signs in through `KEYCLOAK_PUBLIC_URL` on the same server.
That is why `localhost` in `PUBLIC_SERVER`/`PORTAL_SERVER` does not have to work
inside the containers. For the full local walkthrough, see
[Local setup](https://github.com/EMOBase/emobase-docs/blob/main/DEPLOYMENT.md#local-setup-no-public-server).

For Tcas-specific services (OBA, Ontoscope and the extended Swagger UI), append
`-f compose.tcas.yml` to the Compose commands.

## The public and internal URLs

`emobase-deploy` uses two public URLs, a Keycloak realm and a set of internal
container URLs:

| Variable | Meaning | Example |
| --- | --- | --- |
| `PUBLIC_SERVER` | The URL users open for **this species site** | `https://tcas.example.org` |
| `PORTAL_SERVER` | The **public portal** URL used for genomics/JBrowse2/BLAST links | `https://portal.example.org` |
| `PORTAL_INTERNAL_URL` | Portal origin used by nginx for the BLAST proxy | `http://host.docker.internal:9080` |
| `KEYCLOAK_PUBLIC_URL` | This server's browser-facing Keycloak base URL | `https://auth.example.org/keycloak` |
| `KEYCLOAK_REALM` | Shared portal realm or this species' dedicated realm | `ibb` / `ibb_tcas` |
| `KEYCLOAK_CLIENT_ID` | Client ID in that realm | `ibb-client` |
| `DIRECTUS_DB_DATABASE` | This species' database in the local MySQL | `directus_tcas` |
| `INTERNAL_API_*`, `INTERNAL_KEYCLOAK_ISSUER`, `INTERNAL_DIRECTUS_URL` | Full server-side service URLs | `http://phenotypeservice:8080` |

`KEYCLOAK_ISSUER` is derived from `KEYCLOAK_PUBLIC_URL` and `KEYCLOAK_REALM`, so
it points at the Keycloak on this server, not at the portal. For a **shared**
realm, create it or add the species origin with
`emobase-infra/scripts/ensure-shared-realm.sh` before users sign in. A
**dedicated** realm is created with the species origin already allowed.

`PORTAL_SERVER` must be exactly the portal's `PUBLIC_SERVER` (same scheme,
host and port, no trailing slash). `init.sh` strips a trailing slash for you.

`PORTAL_INTERNAL_URL` defaults to `PORTAL_SERVER` when not set. Set it to an
internal address when the portal runs on the same Docker host, so containers
do not go out through the public domain:

- `--local` sets it automatically to
  `http://host.docker.internal:<portal-port>`.
- For a same-host production deployment, set it explicitly, for example
  `http://host.docker.internal:9080` (or another hostname that is reachable
  from this stack's default Docker network).
- On a separate server, leave it equal to `PORTAL_SERVER`.

BLAST is proxied through this stack's nginx so its iframe stays same-origin;
the proxy uses `PORTAL_INTERNAL_URL`. JBrowse2 and browser-facing genomics
links use `PORTAL_SERVER`.

Server-side calls prefer `INTERNAL_API_*`, `INTERNAL_KEYCLOAK_ISSUER` and
`INTERNAL_DIRECTUS_URL`. When those are not set, they fall back to the matching
public URL. The fallback is correct for a separate server; the app only warns
when the public URL is a loopback address and therefore cannot work from inside
a container.

## Adding another species on the same Docker host

Each species checkout needs its own `.env`, data directories, Directus
database/data and containers. Give each stack a distinct `--http-port` (and
matching `--public-server`) and a `--container-prefix`:

```bash
./init.sh \
  --species Dmel \
  --public-server https://dmel.example.org \
  --portal-dir ../emobase-portal-deploy \
  --http-port 9092 \
  --container-prefix dmel

../emobase-infra/scripts/create-database.sh directus_dmel
# Only for the shared realm; choose a dedicated realm in init.sh to skip this.
../emobase-infra/scripts/ensure-shared-realm.sh https://dmel.example.org
docker compose run --rm setup-directus
docker compose up -d --wait
```

## Multiple servers

Each server runs its own `emobase-infra`; only the portal URL is shared between
servers. See the
[deployment guide](https://github.com/EMOBase/emobase-docs/blob/main/DEPLOYMENT.md)
for adding another server.

## What `init.sh` sets

| Setting | Notes |
| --- | --- |
| `MAIN_SPECIES` | 4-letter species code, passed with `--species` |
| `PUBLIC_SERVER` | Species site URL; `http://localhost:<HTTP_PORT>` with `--local` |
| `PORTAL_SERVER` | Public portal URL; read from `--portal-server` or `--portal-dir` |
| `PORTAL_INTERNAL_URL` | Portal URL for containers; local mode uses `host.docker.internal` |
| `DIRECTUS_DB_DATABASE` | `directus_<species>` by default; one database per species |
| `KEYCLOAK_PUBLIC_URL` / `KEYCLOAK_INTERNAL_URL` | Local Keycloak endpoints, copied from `emobase-infra/.env` |
| `KEYCLOAK_REALM` | Portal's shared realm or `ibb_<species>` for a dedicated realm |
| `KEYCLOAK_CLIENT_ID` | Client ID in the selected realm |
| `KEYCLOAK_CLIENT_SECRET` | Shared-realm secret, or a new secret for a dedicated realm |
| `COCO_USERNAME` / `COCO_PASSWORD` | Seed user; shared from infra or created for a dedicated realm |
| `EMOBASE_INFRA_NETWORK` | External Docker network shared with infra and the portal |
| `INTERNAL_API_*`, `INTERNAL_DIRECTUS_URL` | Server-side URLs; generated with Docker service names |
| `INTERNAL_KEYCLOAK_ISSUER` | Local Keycloak base URL + `/realms/<realm>` (server-side) |
| `HTTP_PORT` | Host port for this stack; defaults to `9090` |
| `PUBLIC_DATA_DIR`, `PRIVATE_DATA_DIR`, `IMAGE_DIR` | Host data directories |
| `MYSQL_ROOT_PASSWORD` | Copied from `emobase-infra/.env` |
| Other secrets and credentials | Generated on every run |

The image tags and other optional values remain in `.env`; edit them to pin a
release or SHA. See `example.env` for comments.

`--local` is a local-trial convenience: it uses `localhost` for the browser and
sets `PORTAL_INTERNAL_URL` and the `INTERNAL_*` URLs so containers can still
reach the portal, the local Keycloak and the local services. Use it in the
infra and portal checkouts first, then here.

## Local development

Start `emobase-infra` first so the external `emobase-infra` Docker network and
the local MySQL/Keycloak containers exist. Then build the web UI from the
sibling source tree instead of pulling the published image:

```bash
docker compose -f compose.yml -f compose.local.yml up -d --build
```

`compose.local.yml` is not loaded automatically, so a plain
`docker compose up -d` always uses the published image.

## Updating the species stack

The [deployment guide](https://github.com/EMOBase/emobase-docs/blob/main/DEPLOYMENT.md)
covers the update order across repositories. To update this stack:

```bash
git pull
docker compose pull
docker compose up -d --wait
```

## Notes

The portal's `/public/versions` endpoint is global: until species filtering is
added, the version selector may also list READY versions that belong to other
species hosted on the same portal.

Directus data lives in the local MySQL database named by
`DIRECTUS_DB_DATABASE`; uploaded files still use this stack's `directus-data`
volume. Back up both.

## Remove all docker containers and their data

This is DANGEROUS! It removes this species' containers and volumes, but the
local MySQL database remains in `emobase-infra`.

```bash
docker compose --profile '*' down -v
```

To drop the species database too:

```bash
../emobase-infra/scripts/drop-database.sh directus_tcas
```

## Snapshot and restore Elasticsearch

This applies to this stack's Elasticsearch (host port `9202`).

Snapshot:

```bash
mkdir -p es_bk
chmod o+w es_bk
curl -X PUT "http://localhost:9202/_snapshot/ibb" -d '{
    "type": "fs",
    "settings": {
      "location": "/es-bk",
      "compress": true
    }
  }'
curl -X PUT "http://localhost:9202/_snapshot/ibb/full_backup_20260425?wait_for_completion=true" -d '{
    "indices": "*",
    "include_global_state": true
  }'
```

Copy `es_bk`:

```bash
rsync -avz /source/path/es_bk/ /dest/path/es_bk
```

Restore:

```bash
curl -X PUT "http://localhost:9202/_snapshot/ibb" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "fs",
    "settings": {
      "location": "/es-bk"
    }
  }'
curl -X POST "http://localhost:9202/_snapshot/ibb/full_backup_20260425/_restore?wait_for_completion=true" \
  -H "Content-Type: application/json" \
  -d '{
    "indices": "*",
    "include_global_state": true
  }'
```
