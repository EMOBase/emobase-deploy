# Species `init.sh` reference

`init.sh` generates one species checkout's `.env`. Each species is a separate
clone and a separate Compose project.

## Prerequisites

- A running `emobase-infra` checkout with `.env`
- `../portal/.env` when the portal is a sibling checkout
- Docker Engine 24+ with Compose v2

## Quick run

```bash
./init.sh
```

The species code is required and has no default. For example, enter `Tcas`.

Every question shows a default. Press Enter to accept it. An invalid
interactive answer is rejected and the question is asked again. Values passed
as flags are validated once; an invalid flag stops the script.

## Prompt order

| Question | Default |
| --- | --- |
| Species code | none; required, for example `Tcas` |
| Web UI host port | `9090` |
| Public species URL | detected host IPv4, or localhost with `--local` |
| Portal internal URL | `host.docker.internal` with `--local`, otherwise the portal URL |
| Directus database | `directus_<species>` |
| Compose project/container prefix | species slug |
| Elasticsearch index prefix | species slug |
| Keycloak realm | menu of existing realms plus a new realm |

Without `--local`, the species and portal URLs default to the detected host IPv4
address; enter the public IP or domain if the server is behind NAT.

## Keycloak credentials

The realm and client are created on the portal host, or in the Keycloak admin
UI, before `init.sh` runs. This script only consumes them and never creates a
realm, generates a client secret or calls the Keycloak admin API.

Create the realm and client on the portal first, then pass the result:

```bash
./init.sh \
  --keycloak-public-url https://<portal>/keycloak \
  --keycloak-realm emobase-tcas \
  --keycloak-client-id emobase-tcas-client \
  --keycloak-client-secret '<client secret>' \
  --coco-username coco \
  --coco-password '<seed password>'
```

The client must allow this species origin (`https://<species>/*`) and web
origin. `KEYCLOAK_INTERNAL_URL` stays empty for a remote portal; Compose then
uses the public URL.

## Generated values

The species `.env` contains its public/internal URLs, Directus settings,
realm/client credentials, a new Directus database name,
`EMOBASE_ES_INDEX_PREFIX` and `COMPOSE_FILE` (which adds a species overlay such
as `compose.tcas.yml`). `MYSQL_ROOT_PASSWORD` and the network are read from
`../infra/.env`; Keycloak values come from the portal.

`PUBLIC_HOST` is the hostname part of `PUBLIC_SERVER`, without protocol, port or
path. The species nginx serves only that name and rejects other `Host` headers,
so open the site with the URL in `PUBLIC_SERVER`. Change both values together;
editing `PUBLIC_HOST` alone breaks the site.

Compose appends `/realms/<realm>` to `KEYCLOAK_INTERNAL_URL`, falling back to
`KEYCLOAK_PUBLIC_URL` when it is empty. A remote species leaves it empty.

The Elasticsearch prefix uses lowercase letters, digits, underscore and hyphen,
and must not be `genomics` (reserved for the portal). The stack writes only
`<prefix>-*` indices in the shared instance.

## Flags

| Flag | Meaning |
| --- | --- |
| `--local` | Use localhost for browser URLs and internal host URLs |
| `--species CODE` | Species code |
| `--public-server URL` | Public species URL |
| `--http-port PORT` | Host port for the species UI |
| `--portal-server URL` | Portal URL when there is no local portal checkout |
| `--portal-internal-url URL` | Override the derived container-facing portal origin (`http://host.docker.internal:<portal port>` for a local portal; empty for a remote portal) |
| `--portal-dir DIR` | Portal checkout used to copy the portal URL |
| `--infra-dir DIR` | `emobase-infra` checkout |
| `--directus-db NAME` | Directus database name |
| `--keycloak-public-url URL` | Portal Keycloak base URL (default: the portal checkout) |
| `--keycloak-internal-url URL` | Optional container-facing Keycloak base URL |
| `--keycloak-realm REALM` | Existing realm created on the portal |
| `--keycloak-client-id ID` | Existing client ID from the portal |
| `--keycloak-client-secret SECRET` | Existing client secret from the portal |
| `--coco-username USER` | Seed user name (default `coco`) |
| `--coco-password PASSWORD` | Seed password from the portal |
| `--container-prefix PREFIX` | Compose project/container prefix |
| `--es-index-prefix PREFIX` | Elasticsearch index prefix (default: species slug) |
| `-y`, `--yes` | Accept defaults; Keycloak credentials are still required |
| `-f`, `--force` | Overwrite an existing `.env` |
| `-p`, `--print` | Print the file instead of writing it |
| `-h`, `--help` | Show help |

## Examples

Server using a realm created on the portal:

```bash
./init.sh \
  --species Tcas \
  --public-server https://tcas.example.org \
  --portal-dir ../portal \
  --keycloak-realm emobase-tcas \
  --keycloak-client-id emobase-tcas-client \
  --keycloak-client-secret "$KC_SECRET" \
  --coco-password "$COCO_PASSWORD"
```

## After init

Create the Directus database, initialise Directus and start:

```bash
../infra/scripts/create-database.sh directus_tcas
docker compose run --rm setup-directus
docker compose up -d --wait
```

The realm already exists on the portal; do not create it here.
