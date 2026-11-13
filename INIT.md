# Species `init.sh` reference

`init.sh` generates one species checkout's `.env`. Each species is a separate
clone and a separate Compose project.

## Prerequisites

- A running `emobase-infra` checkout with `.env`
- `../emobase-portal-deploy/.env` when the portal is a sibling checkout
- Docker Engine 24+ with Compose v2

## Quick run

```bash
./init.sh
```

The species code is required and has no default. For example, enter `Tcas`.

## Prompt order

| Question | Default |
| --- | --- |
| Species code | none; required, for example `Tcas` |
| Web UI host port | `9090` |
| Public species URL | detected host IPv4, or localhost with `--local` |
| Portal internal URL | `host.docker.internal` with `--local`, otherwise the portal URL |
| Directus database | `directus_<species>` |
| Compose project/container prefix | species slug |
| Keycloak realm | menu of existing realms plus a new realm |

Without `--local`, the species and portal URLs default to the detected host IPv4
address; enter the public IP or domain if the server is behind NAT.

## Realm menu

`init.sh` scans the portal and sibling species checkouts for reusable realms:

```text
1) Realm 'emobase-portal' — used by portal
2) Realm 'emobase-tcas' — used by Tcas
3) Create a new independent realm [emobase-dmel]
```

- Joining copies the realm name, client ID, client secret and seed credentials
  from the owning checkout.
- A new realm defaults to `emobase-<species>` and `emobase-<species>-client`.
- The selected mode is written as `KEYCLOAK_REALM_MODE=joined|dedicated`.

Non-interactive forms:

```bash
--keycloak-realm join:emobase-portal
--keycloak-realm new:emobase-dmel
```

A plain realm name creates a new realm unless it matches a discovered realm, in
which case it joins that realm.

## Generated values

The species `.env` contains its public/internal URLs, Directus settings,
realm/client credentials, `KEYCLOAK_REALM_MODE`, and a new Directus database
name. `MYSQL_ROOT_PASSWORD` and the Keycloak URLs are read from
`../emobase-infra/.env`.

## Flags

| Flag | Meaning |
| --- | --- |
| `--local` | Use localhost for browser URLs and internal host URLs |
| `--species CODE` | Species code |
| `--public-server URL` | Public species URL |
| `--http-port PORT` | Host port for the species UI |
| `--portal-server URL` | Portal URL when there is no local portal checkout |
| `--portal-internal-url URL` | Portal URL used inside containers |
| `--portal-dir DIR` | Portal checkout used to copy the portal URL |
| `--infra-dir DIR` | `emobase-infra` checkout |
| `--directus-db NAME` | Directus database name |
| `--keycloak-realm join:REALM\|new:REALM` | Join or create a realm |
| `--keycloak-client-id ID` | Client ID override |
| `--keycloak-client-secret SECRET` | Client secret override |
| `--coco-username USER` | Seed user name |
| `--coco-password PASSWORD` | Seed password |
| `--container-prefix PREFIX` | Compose project/container prefix |
| `-y`, `--yes` | Accept defaults; joins the first discovered realm |
| `-f`, `--force` | Overwrite an existing `.env` |
| `-p`, `--print` | Print the file instead of writing it |
| `-h`, `--help` | Show help |

## Examples

Local trial joining the portal realm:

```bash
./init.sh --local --species Tcas
```

Server joining the portal realm:

```bash
./init.sh \
  --species Tcas \
  --public-server https://tcas.example.org \
  --portal-dir ../emobase-portal-deploy \
  --keycloak-realm join:emobase-portal
```

New independent realm:

```bash
./init.sh \
  --species Dmel \
  --public-server https://dmel.example.org \
  --portal-dir ../emobase-portal-deploy \
  --keycloak-realm new:emobase-dmel \
  --http-port 9091
```

## After init

Create the Directus database, create or extend the realm, initialise Directus,
and start:

```bash
../emobase-infra/scripts/create-database.sh directus_tcas

../emobase-infra/scripts/create-realm.sh \
  --realm "$(grep '^KEYCLOAK_REALM=' .env | cut -d= -f2-)" \
  --origin "$(grep '^PUBLIC_SERVER=' .env | cut -d= -f2-)" \
  --client-id "$(grep '^KEYCLOAK_CLIENT_ID=' .env | cut -d= -f2-)" \
  --client-secret "$(grep '^KEYCLOAK_CLIENT_SECRET=' .env | cut -d= -f2-)" \
  --coco-username "$(grep '^COCO_USERNAME=' .env | cut -d= -f2-)" \
  --coco-password "$(grep '^COCO_PASSWORD=' .env | cut -d= -f2-)" \
  --keep-password --quiet

docker compose run --rm setup-directus
docker compose up -d --wait
```

The `emobase` CLI does this during `species setup`, `up` or `bootstrap`.

See [REALMS.md](https://github.com/EMOBase/emobase-docs/blob/main/REALMS.md)
for realm ownership, sharing, and credential rules.
