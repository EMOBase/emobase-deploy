# EMOBase species deployment

Single-species deployment: the **emobase-web** frontend plus its own MySQL,
Elasticsearch, Keycloak and Directus.

Genomics, JBrowse2 and BLAST are **not** run here. They come from a running
[`emobase-portal-deploy`](../emobase-portal-deploy) stack. The multi-species
portal itself lives in that repository.

> **Starting from an empty server?** The complete two-repository procedure is
> in [`../emobase-portal-deploy/DEPLOYMENT.md`](../emobase-portal-deploy/DEPLOYMENT.md).
> Deploy the portal first, then use the quick start below.

## Prerequisites

- Docker Engine 24+ with Compose v2
- A running portal deployment
- A public URL (or host:port) for this species site
- A public URL for the portal, reachable from this server and from browsers

## Quick start (portal on the same server)

Both repositories are expected side by side:

```text
emobase/
├── emobase-portal-deploy/
└── emobase-deploy/
```

If the portal is not running yet, follow its
[README](../emobase-portal-deploy/README.md) first.

1. Generate `.env`. `--portal-dir` copies the portal's `PUBLIC_SERVER` into
   this stack's `PORTAL_SERVER`, so the two values cannot drift:

   ```bash
   ./init.sh \
     --species Tcas \
     --public-server https://tcas.example.org \
     --portal-dir ../emobase-portal-deploy
   ```

   If the portal checkout is named `../emobase-portal-deploy`, the flag can be
   omitted; `init.sh` finds it automatically.

2. Initialise Directus, then start the stack:

   ```bash
   docker compose run --rm setup-directus
   docker compose up -d --wait
   ```

3. Open `${PUBLIC_SERVER}` and sign in with the seeded `COCO_USERNAME` /
   `COCO_PASSWORD` from `.env`. The password is temporary; Keycloak asks for a
   new one on first login.

### Local trial (no domain)

If the portal is already running locally, start the species stack the same way:

```bash
./init.sh --local --species Tcas
docker compose run --rm setup-directus
docker compose up -d --wait
```

`--local` puts the machine's LAN IP in `PUBLIC_SERVER`, and the portal URL is
copied from `../emobase-portal-deploy/.env` into `PORTAL_SERVER`. Open the URL
printed by `init.sh`.

Do not use `localhost` for `PORTAL_SERVER`: the species nginx runs in a
container and proxies `/ibb/blast/` to it, so `localhost` would mean the
container itself. For the full local walkthrough, see
[Local setup](../emobase-portal-deploy/DEPLOYMENT.md#local-setup-no-public-server).

For Tcas-specific services (OBA, Ontoscope and the extended Swagger UI), append
`-f compose.tcas.yml` to the Compose commands.

## The two URLs

`emobase-deploy` uses two independent public URLs:

| Variable | Meaning | Example |
| --- | --- | --- |
| `PUBLIC_SERVER` | The URL users open for **this species site** | `https://tcas.example.org` |
| `PORTAL_SERVER` | The **portal** URL serving genomics/JBrowse2/BLAST | `https://portal.example.org` |

`PORTAL_SERVER` must be exactly the portal's `PUBLIC_SERVER` (same scheme,
host and port, no trailing slash). `init.sh` strips a trailing slash for you.

- BLAST is proxied through this stack's nginx so its iframe stays same-origin;
  therefore this server must be able to reach `PORTAL_SERVER`.
- JBrowse2 and genomics links point at `PORTAL_SERVER` directly, so browsers
  must be able to reach it as well.

## Deploying on a separate server (another species later)

The portal is the only shared dependency. On a new species server:

```bash
git clone https://github.com/EMOBase/emobase-deploy.git
cd emobase-deploy
./init.sh \
  --species <SpeciesCode> \
  --public-server https://<species>.example.org \
  --portal-server https://portal.example.org
docker compose run --rm setup-directus
docker compose up -d --wait
```

Check that the portal is reachable before starting:

```bash
curl -fsS https://portal.example.org/ibb/api/genomicsservice/v1/public/versions?status=READY >/dev/null
```

Each species checkout needs its own `.env`, data directories, Directus data and
containers. If two species stacks share one Docker host, give each one a
distinct `--http-port` (and matching `--public-server`) and a
`--container-prefix`:

```bash
./init.sh \
  --species Dmel \
  --public-server https://dmel.example.org \
  --portal-dir ../emobase-portal-deploy \
  --http-port 9092 \
  --container-prefix dmel
```

## What `init.sh` sets

| Setting | Notes |
| --- | --- |
| `MAIN_SPECIES` | 4-letter species code, passed with `--species` |
| `PUBLIC_SERVER` | Species site URL; `http://localhost:<HTTP_PORT>`, or the LAN IP with `--local` |
| `PORTAL_SERVER` | Portal URL; read from `--portal-server` or `--portal-dir` |
| `HTTP_PORT` | Host port for this stack; defaults to `9090` |
| `PUBLIC_DATA_DIR`, `PRIVATE_DATA_DIR`, `IMAGE_DIR` | Host data directories |
| Secrets and credentials | Generated on every run |

The image tags and other optional values remain in `.env`; edit them to pin a
release or SHA. See `example.env` for comments.

`--local` is a local-trial convenience: it detects the machine's LAN IP and
uses it for `PUBLIC_SERVER`. Use it in the portal checkout first, then here.

## Local development

To build the web UI from the sibling source tree instead of pulling the
published image:

```bash
docker compose -f compose.yml -f compose.local.yml up -d --build
```

`compose.local.yml` is not loaded automatically, so a plain
`docker compose up -d` always uses the published image.

## Updating

Update the portal first so its API and database migrations are current, then:

```bash
git pull
docker compose pull
docker compose up -d --wait
```

## Notes

The portal's `/public/versions` endpoint is global: until species filtering is
added, the version selector may also list READY versions that belong to other
species hosted on the same portal.

## Remove all docker containers and their data

This is DANGEROUS!

```bash
docker compose --profile '*' down -v
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
