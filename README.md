# iBeetle-Base deploy scripts and configurations

Requirements:
- docker
- docker compose

## Start the services

```bash
bash init.sh
docker compose up -d --wait
docker compose run --rm setup-directus
```

## Remove all docker containers and their data

```bash
docker compose --profile '*' down -v
```

## Copy databases

Install elasticdump:

```bash
npm install -g elasticdump
```

For example:

```bash
elasticdump \
  --input http://localhost:9200 \
  --input-index=publicationservice-publications \
  --output https://ibb-test.vm19002.virt.gwdg.de/ibb/es/ \
  --output-index=publicationservice-publications
```
