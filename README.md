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

Keep the repositories side by side:

```text
emobase/
├── emobase-infra/
├── emobase-portal-deploy/
└── emobase-deploy/
```

The infra and portal must already be running.

```bash
./init.sh

../emobase-infra/scripts/create-database.sh directus_<species>
../emobase-infra/scripts/create-realm.sh \
  --realm "$(grep '^KEYCLOAK_REALM=' .env | cut -d= -f2-)" \
  --origin "$(grep '^PUBLIC_SERVER=' .env | cut -d= -f2-)" \
  --client-id "$(grep '^KEYCLOAK_CLIENT_ID=' .env | cut -d= -f2-)" \
  --client-secret "$(grep '^KEYCLOAK_CLIENT_SECRET=' .env | cut -d= -f2-)" \
  --coco-username "$(grep '^COCO_USERNAME=' .env | cut -d= -f2-)" \
  --coco-password "$(grep '^COCO_PASSWORD=' .env | cut -d= -f2-)" \
  --keep-password --quiet

docker compose run --rm setup-directus
docker compose up -d --wait
```

Use `./init.sh --local --species Tcas` for a same-machine trial.

The realm menu lets this species join the portal or another species realm, or
create a new independent realm.

- [`init.sh` reference](INIT.md)
- [Realm ownership](https://github.com/EMOBase/emobase-docs/blob/main/REALMS.md)
- [Full deployment order](https://github.com/EMOBase/emobase-docs/blob/main/DEPLOYMENT.md)

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
| `KEYCLOAK_REALM` | Joined realm or this species' new realm | `emobase-portal` / `emobase-tcas` |
| `KEYCLOAK_CLIENT_ID` | Client ID in that realm | `emobase-tcas-client` |
| `DIRECTUS_DB_DATABASE` | This species' database in the local MySQL | `directus_tcas` |
| `INTERNAL_API_*`, `INTERNAL_KEYCLOAK_ISSUER`, `INTERNAL_DIRECTUS_URL` | Full server-side service URLs | `http://phenotypeservice:8080` |

`KEYCLOAK_ISSUER` is derived from `KEYCLOAK_PUBLIC_URL` and `KEYCLOAK_REALM`, so
it points at the Keycloak on this server, not at the portal. For a joined
realm, add this species origin with
`emobase-infra/scripts/create-realm.sh --keep-password` before users sign in. A
new realm is created with the species origin already allowed.

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
# Create or update the realm chosen by init.sh.
../emobase-infra/scripts/create-realm.sh \
  --realm emobase-dmel \
  --origin https://dmel.example.org \
  --client-id emobase-dmel-client \
  --client-secret "<KEYCLOAK_CLIENT_SECRET from .env>" \
  --coco-username coco \
  --coco-password "<COCO_PASSWORD from .env>" \
  --keep-password --quiet
docker compose run --rm setup-directus
docker compose up -d --wait
```

## Multiple servers

Each server runs its own `emobase-infra`; only the portal URL is shared between
servers. See the
[deployment guide](https://github.com/EMOBase/emobase-docs/blob/main/DEPLOYMENT.md)
for adding another server.

## What `init.sh` sets

See the [`init.sh` reference](INIT.md) for prompt order, flags, generated
values and the realm menu. Image tags remain in `.env`; edit them to pin a
release or SHA. See `example.env` for comments.

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
