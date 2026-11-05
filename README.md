# EMOBase deploy scripts and configurations

Single-species deployment (`emobase-web` frontend in front of the ES-backed
species services). The multi-species stack lives in `emobase-portal-deploy`.

Requirements:
- docker
- docker compose
- a public domain with SSL

Application images are published by GitHub Actions to GitHub Container
Registry, so only this repository is needed on the deployment server — no
sibling `emobase-web` source tree.

| Variable | Default |
| --- | --- |
| `EMOBASE_WEB_IMAGE` | `ghcr.io/emobase/emobase-web:dev` |

Pin a release tag (`vX.Y.Z`) or an immutable `sha-<short>` tag in `.env` for
production.

## Start the services

```bash
bash init.sh
docker compose run --rm setup-directus
docker compose up -d --wait
```

For Tcas, replace `docker compose` with `docker compose -f compose.yml -f compose.tcas.yml`

## Local development

To build the web UI from the sibling source tree instead of pulling the
published image:

```bash
docker compose -f compose.yml -f compose.local.yml up -d --build
```

`compose.local.yml` is not loaded automatically, so a plain
`docker compose up -d` always uses the published image.

## Genomics, JBrowse2 and BLAST

This single-species stack does not run `emobase-genomics`, JBrowse2 or BLAST.
Those are provided by the multi-species portal deployment. Set
`GENOMICS_SERVER` in `.env` to the portal's public origin (no trailing slash),
for example `https://portal.example.com`. The web UI uses it for the genomics
API, and nginx proxies the portal's `/ibb/blast/` and `/ibb/jbrowse2/` through
this deployment's own origin.

`nginx/nginx.conf.template` is rendered by the nginx image entrypoint at
container start, substituting `GENOMICS_SERVER`. Proxying BLAST and JBrowse
this way keeps the browser on one origin: the SequenceServer session cookie is
first-party, and the iframe form submission does not depend on third-party or
same-site cookie behaviour.

Local example:

```env
PUBLIC_SERVER=http://localhost:9090
GENOMICS_SERVER=http://192.168.6.17:9091
```

Production example:

```env
PUBLIC_SERVER=https://ptep.emobase.uni-goettingen.de
GENOMICS_SERVER=https://emobase.uni-goettingen.de
```

The portal must contain the assemblies for `MAIN_SPECIES`. Note that the
portal's `/public/versions` endpoint is global: until species filtering is
added, the version selector may also list READY versions that belong to other
species hosted on the same portal.

## Remove all docker containers and their data

This is DANGEROUS!

```bash
docker compose --profile '*' down -v
```



## Snapshot and restore elasticsearch

Snapshot

```
mkdir es_bk
chmod o+w es_bk
curl -X PUT "http://localhost:9200/_snapshot/ibb" -d '{
    "type": "fs",
    "settings": {
      "location": "/es-bk",
      "compress": true
    }
  }'
curl -X PUT "http://localhost:9200/_snapshot/ibb/full_backup_20260425?wait_for_completion=true"  -d '{
    "indices": "*",
    "include_global_state": true
  }'
```

Copy `es_bk`

```
rsync -avz /source/path/es_bk/ /dest/path/es_bk
```

Restore

```
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
