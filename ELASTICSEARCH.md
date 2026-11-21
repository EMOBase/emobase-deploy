# Elasticsearch

This stack has no Elasticsearch container. Its services keep using `es:9200`;
the `es-proxy` sidecar resolves that name locally and forwards to
`elasticsearch:9200` in `emobase-infra`. The sidecar is the only service on the
shared infra network, so the application services do not expose their generic
names to other species.

An existing checkout that ran its own Elasticsearch must remove the old
container before `emobase-infra` can bind its loopback port 9202:

```bash
docker compose --profile '*' down --remove-orphans
```

This keeps the old `<project>_es-data` volume for migration. The new stack
ignores it; delete it only after the data has been moved. `emobase up` already
passes `--remove-orphans`.

## Index prefixes

Each stack writes only indices under `EMOBASE_ES_INDEX_PREFIX` (default: the
lowercase species code such as `tcas`):

| Service | Index |
| --- | --- |
| `imageservice` | `<prefix>-imageservice-metadata-*` |
| `phenotypeservice` | `<prefix>-phenotypeservice-phenotypegroups` |
| `goannotationservice` | `<prefix>-goannotationservice-<species>` |
| `publicationservice` | `<prefix>-publicationservice-publications` |
| `ontologyservice` | `<prefix>-ontologyservice-ontologies-*` |

The portal uses `genomics`, which `init.sh` refuses. Prefixes separate data;
they are not an authorization boundary inside the shared instance.

## Migrating and cleanup

A checkout created before the shared instance has no
`EMOBASE_ES_INDEX_PREFIX`. Add `EMOBASE_ES_INDEX_PREFIX=<species>` to its
`.env` and re-import the data; the old unprefixed indices are left untouched.

Changing the prefix after first start makes the services create a new, empty
set. Delete the old indices deliberately with:

```bash
../infra/scripts/delete-es-indices.sh --yes tcas
```

`emobase species remove --purge` and `emobase prune` run the same helper after
the stack is gone. Elasticsearch snapshots and restores are documented in
[`emobase-infra/BACKUP.md`](https://github.com/EMOBase/emobase-infra/blob/main/BACKUP.md).
