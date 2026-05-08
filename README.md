# EMOBase deploy scripts and configurations

Requirements:
- docker
- docker compose
- a public domain with SSL

## Start the services

```bash
bash init.sh
docker compose run --rm migrate-genomics-db && docker compose run --rm migrate-genomics-es
docker compose up -d --wait
docker compose run --rm setup-directus setup-blast setup-jbrowse2
```

For Tcas, replace `docker compose` with `docker compose -f compose.yml -f compose.tcas.yml`

## Remove all docker containers and their data

This is DANGEROUS!

```bash
docker compose --profile '*' down -v
```
