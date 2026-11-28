# EMOBase species deployment

Single-species deployment: the **emobase-web** frontend, its Quarkus services
and Directus. MySQL and Elasticsearch are shared **per server** in
[`emobase-infra`](https://github.com/EMOBase/emobase-infra); Keycloak is hosted
by the portal deployment and used by every species on that server.

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
- A running portal deployment with Keycloak

## Quick start

If the portal runs on this same server, keep the checkouts side by side so
`init.sh` can read its URL from the portal checkout:

```text
emobase/
├── infra/
├── portal/
└── <Species>/
```

The infra and portal must already be running. If the portal is on another
server, run `./init.sh --portal-server URL` instead; the rest of the commands
are the same.

Create the realm and client on the portal host first (see
`emobase-portal-deploy/scripts/create-realm.sh` or the Keycloak admin UI), then:

```bash
./init.sh \
  --keycloak-public-url https://<portal>/keycloak \
  --keycloak-realm emobase-<species> \
  --keycloak-client-id emobase-<species>-client \
  --keycloak-client-secret '<client secret>' \
  --coco-password '<seed password>'

../infra/scripts/create-database.sh directus_<species>
docker compose run --rm setup-directus
docker compose up -d --wait
```

Use `./init.sh --local --species Tcas` for a same-machine trial.

The realm and client are created on the portal host, or in the Keycloak admin
UI, before this stack starts. `init.sh` only consumes the credentials; it never
creates a realm or generates a client secret. See the
[`init.sh` reference](INIT.md) for the flags.

## The public and internal URLs

`emobase-deploy` uses two public URLs, a Keycloak realm and a set of internal
container URLs:

| Variable | Meaning | Example |
| --- | --- | --- |
| `PUBLIC_SERVER` | The URL users open for **this species site** | `https://tcas.example.org` |
| `PORTAL_SERVER` | The **public portal** URL used for genomics/JBrowse2/BLAST links | `https://portal.example.org` |
| `PORTAL_INTERNAL_URL` | Portal origin for the BLAST proxy and derived API URLs | `http://host.docker.internal:9080` |
| `KEYCLOAK_PUBLIC_URL` | This server's browser-facing Keycloak base URL | `https://auth.example.org/keycloak` |
| `KEYCLOAK_INTERNAL_URL` | Keycloak base URL containers use; empty falls back to the public URL | empty (remote), or an internal portal address |
| `KEYCLOAK_REALM` | Existing realm created on the portal | `emobase-tcas` |
| `KEYCLOAK_CLIENT_ID` | Client ID in that realm | `emobase-tcas-client` |
| `DIRECTUS_DB_DATABASE` | This species' database in the local MySQL | `directus_tcas` |
| `INTERNAL_DIRECTUS_URL` | Server-side Directus URL written to `.env` | `http://directus:8055` |

`KEYCLOAK_ISSUER` is derived from `KEYCLOAK_PUBLIC_URL` and `KEYCLOAK_REALM`,
so it points at the portal Keycloak. The client's redirect URIs must include
this species origin; the portal-side realm creation adds it.

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
- On a separate server, leave it empty; Compose falls back to `PORTAL_SERVER`.

BLAST is proxied through this stack's nginx so its iframe stays same-origin;
the proxy uses `PORTAL_INTERNAL_URL`. JBrowse2 and browser-facing genomics
links use `PORTAL_SERVER`.

Server-side service URLs are Compose defaults. `INTERNAL_API_GENOMICS_SERVICE`
and `GENOMICSSERVICE_BASE_URL` are derived from `PORTAL_INTERNAL_URL`, falling
back to `PORTAL_SERVER` when the portal is remote. The Keycloak issuer is
derived from `KEYCLOAK_INTERNAL_URL` plus `/realms/<realm>`; when that value is
empty, Compose uses `KEYCLOAK_PUBLIC_URL`. A remote species normally leaves it
empty so containers use the portal URL.

## Elasticsearch

This stack uses the shared `emobase-infra` instance through the `es-proxy`
sidecar. Each stack writes only its own `<prefix>-*` indices. See
[ELASTICSEARCH.md](ELASTICSEARCH.md) for the index list, migration from a
per-species instance and prefix cleanup.

## Local development

Start the `infra` checkout first so the external `emobase-infra` Docker network
and the local MySQL/Elasticsearch containers exist. Then build the web
UI from a local source checkout instead of pulling the published image (set
`EMOBASE_WEB_DIR` if it is not next to this checkout):

```bash
docker compose -f compose.yml -f compose.local.yml up -d --build
```

`compose.local.yml` is not loaded automatically, so a plain
`docker compose up -d` always uses the published image. For Tcas, pass all
three files:

```bash
docker compose -f compose.yml -f compose.tcas.yml -f compose.local.yml up -d --build
```

## Updating the species stack

The [deployment guide](https://github.com/EMOBase/emobase-docs/blob/main/DEPLOYMENT.md)
covers the update order across repositories. To update this stack:

```bash
git pull
docker compose pull
docker compose up -d --wait
```

Image tags live in `.env`; pin a release or SHA instead of a moving branch
tag. `example.env` documents the available settings.

## Remove all docker containers and their data

This is DANGEROUS! It removes this species' containers and volumes, including
the `directus-data` uploads volume, but the shared MySQL database and
Elasticsearch indices remain in `emobase-infra`. Back up the database and
uploads first; see the
[backup guide](https://github.com/EMOBase/emobase-docs/blob/main/BACKUP.md).

```bash
docker compose --profile '*' down -v
```

To drop the species database and indices too:

```bash
../infra/scripts/drop-database.sh directus_tcas
../infra/scripts/delete-es-indices.sh --yes tcas
```
