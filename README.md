# EMOBase deploy scripts and configurations

Requirements:
- docker
- docker compose
- a public domain with SSL

## Start the services

```bash
bash init.sh
docker compose run --rm setup-directus
docker compose up -d --wait
```

For Tcas, replace `docker compose` with `docker compose -f compose.yml -f compose.tcas.yml`

## Genomics, JBrowse2 and BLAST

This single-species stack does not run `emobase-genomics`, JBrowse2 or BLAST.
Those are provided by the multi-species portal deployment. Set
`GENOMICS_SERVER` in `.env` to the portal's public origin (no trailing slash),
for example `https://portal.example.com`. The web UI uses it for the genomics
API, JBrowse2 and BLAST links.

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
