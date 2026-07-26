# EMOBase deploy scripts and configurations

Requirements:
- docker
- docker compose
- a public domain with SSL

## Start the services

```bash
bash init.sh
docker compose run --rm migrate-genomics-db
docker compose run --rm migrate-genomics-es
docker compose run --rm setup-directus
docker compose run --rm setup-jbrowse2-web
docker compose up -d --wait
```

For Tcas, replace `docker compose` with `docker compose -f compose.yml -f compose.tcas.yml`

## Remove all docker containers and their data

This is DANGEROUS!

```bash
docker compose --profile '*' down -v
```
