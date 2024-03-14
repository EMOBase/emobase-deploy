# iBeetle-Base deploy scripts and configurations

Requirements:
- docker
- docker compose

## Start the services

```bash
docker compose up -d
```

## Copy databases

For example:

```bash
elasticdump \
  --input http://localhost:9200 \
  --input-index=publicationservice-publications \
  --output https://ibb-test.vm19002.virt.gwdg.de/ibb/es/ \
  --output-index=publicationservice-publications
```
