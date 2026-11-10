# EMOBase species deployment

Single-species deployment: the **emobase-web** frontend plus its own
Elasticsearch and Directus. MySQL and Keycloak are shared: they run once in
[`emobase-infra`](../emobase-infra) and are used by the portal and every species
stack.

Genomics, JBrowse2 and BLAST are **not** run here. They come from a running
[`emobase-portal-deploy`](../emobase-portal-deploy) stack. The multi-species
portal itself lives in that repository.

> **Starting from an empty server?** The complete three-repository procedure is
> in [`../emobase-portal-deploy/DEPLOYMENT.md`](../emobase-portal-deploy/DEPLOYMENT.md).
> Deploy the shared infrastructure and the portal first, then use the quick
> start below.

## Prerequisites

- Docker Engine 24+ with Compose v2
- A running `emobase-infra` stack with its `.env`
- `python3` on the Docker host for `emobase-infra/scripts/allow-origin.sh`
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

If the shared infrastructure or portal is not running yet, follow their READMEs
first.

1. Generate `.env`. `--portal-dir` copies the portal's `PUBLIC_SERVER` into
   this stack's `PORTAL_SERVER`, so the two values cannot drift. The shared
   MySQL/Keycloak secrets are read from `../emobase-infra/.env` automatically:

   ```bash
   ./init.sh \
     --species Tcas \
     --public-server https://tcas.example.org \
     --portal-dir ../emobase-portal-deploy
   ```

   If the portal checkout is named `../emobase-portal-deploy`, the flag can be
   omitted; `init.sh` finds it automatically. When both stacks are on the same
   Docker host, add `--portal-internal-url http://host.docker.internal:9080` to
   keep container-to-portal traffic off the public domain.

   `init.sh` derives `DIRECTUS_DB_DATABASE=directus_tcas` (one database per
   species). Use `--directus-db` to override it.

2. Create the Directus database and register this site with the shared
   Keycloak:

   ```bash
   ../emobase-infra/scripts/create-database.sh directus_tcas
   ../emobase-infra/scripts/allow-origin.sh https://tcas.example.org
   ```

   `allow-origin.sh` adds this species origin to the shared `ibb-client` and is
   safe to run again.

3. Initialise Directus, then start the stack:

   ```bash
   docker compose run --rm setup-directus
   docker compose up -d --wait
   ```

4. Open `${PUBLIC_SERVER}` and sign in with the seeded `COCO_USERNAME` /
   `COCO_PASSWORD` from `../emobase-infra/.env`. The password is temporary;
   Keycloak asks for a new one on first login.

### Local trial (no domain)

Start `emobase-infra` and the portal locally first. Then start the species
stack:

```bash
./init.sh --local --species Tcas
../emobase-infra/scripts/create-database.sh directus_tcas
../emobase-infra/scripts/allow-origin.sh http://localhost:9090
docker compose run --rm setup-directus
docker compose up -d --wait
```

`--local` uses `localhost` for the browser URLs and sets the internal URLs
needed by the containers. Open the URL printed by `init.sh`.

The species nginx uses `PORTAL_INTERNAL_URL` for BLAST, and SSR calls use
`INTERNAL_API_*`, `INTERNAL_KEYCLOAK_ISSUER` and `INTERNAL_DIRECTUS_URL`.
`INTERNAL_KEYCLOAK_ISSUER` points at the portal origin, which proxies the
shared Keycloak; the browser also signs in through the portal origin. That is
why `localhost` in `PUBLIC_SERVER`/`PORTAL_SERVER` does not have to work inside
the containers. For the full local walkthrough, see
[Local setup](../emobase-portal-deploy/DEPLOYMENT.md#local-setup-no-public-server).

For Tcas-specific services (OBA, Ontoscope and the extended Swagger UI), append
`-f compose.tcas.yml` to the Compose commands.

## The public and internal URLs

`emobase-deploy` uses two public URLs and a set of internal container URLs:

| Variable | Meaning | Example |
| --- | --- | --- |
| `PUBLIC_SERVER` | The URL users open for **this species site** | `https://tcas.example.org` |
| `PORTAL_SERVER` | The **public portal** URL used for browser links and Keycloak sign-in | `https://portal.example.org` |
| `PORTAL_INTERNAL_URL` | Portal origin used by nginx for the BLAST proxy | `http://host.docker.internal:9080` |
| `DIRECTUS_DB_DATABASE` | This species' database in the shared MySQL | `directus_tcas` |
| `INTERNAL_API_*`, `INTERNAL_KEYCLOAK_ISSUER`, `INTERNAL_DIRECTUS_URL` | Full server-side service URLs | `http://phenotypeservice:8080` |

`KEYCLOAK_ISSUER` is derived from `PORTAL_SERVER` because the shared Keycloak
has one public origin: the portal. Every species origin must be registered with
`emobase-infra/scripts/allow-origin.sh` before users sign in.

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
../emobase-infra/scripts/allow-origin.sh https://dmel.example.org
docker compose run --rm setup-directus
docker compose up -d --wait
```

## Running a species on another Docker host

The default layout assumes one Docker host: `emobase-infra` creates a private
Docker network and does not publish MySQL/Keycloak host ports. To use a
different host:

1. Make the shared services reachable (private network/VPN, or explicit port
   mappings and firewall rules for MySQL and Keycloak).
2. Create a Docker network named `emobase-infra` on the species host (the
   compose file declares it external), or use a compose override that removes
   that network.
3. Copy `emobase-infra/.env` to the new host (or pass `--infra-dir` to a
   directory holding it) so `init.sh` can read the shared secrets. Set
   `DIRECTUS_DB_HOST` / `DIRECTUS_DB_PORT` and `INTERNAL_KEYCLOAK_ISSUER` to
   the reachable addresses.
4. Run `init.sh` with `--portal-server https://portal.example.org`.
5. On the infra host, create the species database and allow its origin.

Check that the portal is reachable before starting:

```bash
curl -fsS https://portal.example.org/ibb/api/genomicsservice/v1/public/versions?status=READY >/dev/null
```

## What `init.sh` sets

| Setting | Notes |
| --- | --- |
| `MAIN_SPECIES` | 4-letter species code, passed with `--species` |
| `PUBLIC_SERVER` | Species site URL; `http://localhost:<HTTP_PORT>` with `--local` |
| `PORTAL_SERVER` | Public portal URL; read from `--portal-server`, `--portal-dir` or `emobase-infra/.env` |
| `PORTAL_INTERNAL_URL` | Portal URL for containers; local mode uses `host.docker.internal` |
| `DIRECTUS_DB_DATABASE` | `directus_<species>` by default; one database per species |
| `EMOBASE_INFRA_NETWORK` | External Docker network shared with infra and the portal |
| `INTERNAL_API_*`, `INTERNAL_DIRECTUS_URL` | Server-side URLs; generated with Docker service names |
| `INTERNAL_KEYCLOAK_ISSUER` | Portal origin + `/ibb/keycloak/realms/ibb` (server-side) |
| `HTTP_PORT` | Host port for this stack; defaults to `9090` |
| `PUBLIC_DATA_DIR`, `PRIVATE_DATA_DIR`, `IMAGE_DIR` | Host data directories |
| `MYSQL_ROOT_PASSWORD`, `KEYCLOAK_CLIENT_SECRET` | Copied from `emobase-infra/.env` |
| Other secrets and credentials | Generated on every run |

The image tags and other optional values remain in `.env`; edit them to pin a
release or SHA. See `example.env` for comments.

`--local` is a local-trial convenience: it uses `localhost` for the browser and
sets `PORTAL_INTERNAL_URL` and the `INTERNAL_*` URLs so containers can still
reach the portal and the local services. Use it in the portal checkout first,
then here.

## Local development

Start `emobase-infra` first so the external `emobase-infra` Docker network and
the shared MySQL/Keycloak containers exist. Then build the web UI from the
sibling source tree instead of pulling the published image:

```bash
docker compose -f compose.yml -f compose.local.yml up -d --build
```

`compose.local.yml` is not loaded automatically, so a plain
`docker compose up -d` always uses the published image.

## Updating

Update `emobase-infra` first, then the portal so its API and database
migrations are current, then:

```bash
git pull
docker compose pull
docker compose up -d --wait
```

## Notes

The portal's `/public/versions` endpoint is global: until species filtering is
added, the version selector may also list READY versions that belong to other
species hosted on the same portal.

Directus data lives in the shared MySQL database named by
`DIRECTUS_DB_DATABASE`; uploaded files still use this stack's `directus-data`
volume. Back up both.

## Remove all docker containers and their data

This is DANGEROUS! It removes this species' containers and volumes, but the
shared MySQL database remains in `emobase-infra`.

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
