# EMOBase deploy scripts and configurations

Requirements:
- docker
- docker compose
- a public domain with SSL

## Start the services

```bash
bash init.sh
docker compose run --rm setup-directus
docker compose run --rm setup-blast
docker compose run --rm setup-jbrowse2
docker compose up -d --wait
```

For Tcas, replace `docker compose` with `docker compose -f compose.yml -f compose.tcas.yml`

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
