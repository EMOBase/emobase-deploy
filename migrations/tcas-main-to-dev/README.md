# Migrating Tcas from `main` to `dev`

> **One-time production migration.** Delete this folder after the migration is
> verified.
>
> This is not a fresh deployment. It copies live data, replaces the infra
> Keycloak database, points Apache at the new stack and later stops the old
> site. Read the whole runbook before running any command, and do not continue
> past a failed checkpoint.

This runbook migrates the running Tcas deployment to the `dev` layout with
`emobase-infra`, while keeping the old stack available for rollback.

The old stack stays live while the new one is prepared:

|                 | Old stack                                              | New stack                                        |
| --------------- | ------------------------------------------------------ | ------------------------------------------------ |
| Compose project | `COMPOSE_PROJECT_NAME` from old `.env` (default `ibb`) | `tcas`                                           |
| Species site    | `HTTP_PORT` from old `.env` (default `9090`)           | `9092`                                           |
| Keycloak        | legacy at `/ibb/keycloak`                              | infra at `/keycloak`, port `8181`, public on 443 |
| Elasticsearch   | old stack, `9202`                                      | infra, host port `9204`                          |
| Public URL      | `<TCAS_URL>`, served by the old stack                  | `<TCAS_URL>`, served by the new stack            |

The old checkout, project name, volumes and container names are not changed.
The new stack uses separate volumes and a separate Directus database.

The script reads the old project name, old HTTP port and data paths from
`OLD_SPECIES_DIR/.env`, then uses those values to locate the old stack and
configure the new one.

## 1. Preconditions

Stop before changing anything if any of these is false.

- The portal's default version has the Tcas assembly. Without it, the new site
  has no genomics, JBrowse2 or BLAST data.

- The current Keycloak admin credentials are available. They are either in the
  old `.env` (`KEYCLOAK_ADMIN`, `KEYCLOAK_ADMIN_PASSWORD`) or will be supplied
  in `migration.env`. The copied database keeps the current admin account.

- The old Keycloak is 24.0.3, the same version as `emobase-infra`. The
  migration copies its database, not the schema, so a different version can
  fail on startup. Check with
  `docker exec <old-keycloak-container> /opt/keycloak/bin/kc.sh --version`.

- There is enough local disk for the two checkouts (`emobase-deploy` on `dev`
  and `emobase-infra`) and the local copies (`data/private`, `oba/`, the
  Directus uploads volume, MySQL dumps and the Elasticsearch snapshot).

- At least 3 GB of RAM is available for the new setup (`emobase-infra` plus
  the Tcas stack). Check `free -m` before starting.

- The old data paths in `.env` exist and are readable.

- Docker/Compose access is available, and Apache can be edited and reloaded.

- Ports `9092` (new species), `9204` (new infra ES) and `8181` (new infra
  Keycloak) are free.

- The old `mysql`, `keycloak` and `es` services are running, and the old
  Directus volume exists.

## 2. Get the new checkout and configure

Clone the target `dev` checkout:

```bash
mkdir -p <NEW_WORKSPACE>
cd <NEW_WORKSPACE>
git clone --branch dev https://github.com/EMOBase/emobase-deploy.git Tcas
cd Tcas/migrations/tcas-main-to-dev
```

The script runs from this checkout. It reads the old checkout from
`OLD_SPECIES_DIR` and clones `emobase-infra` itself.

Create the config interactively:

```bash
./migrate.sh init
```

It asks for the old checkout, workspace, backup directory, Tcas URL, Keycloak
URL and portal URL, then writes `migration.env`. Press Enter to accept a
default. All other values use defaults or the existing config; edit
`migration.env` to change them, or rerun `./migrate.sh init --force`.

`SPECIES_CODE`, `REALM` and `CLIENT_ID` are taken from the old `.env` when
present, otherwise `Tcas`, `ibb` and `ibb-client`.

`migration.env` is ignored by git. The values are:

| Variable | Default | Meaning |
| --- | --- | --- |
| `OLD_SPECIES_DIR` | required | Existing running Tcas checkout; read-only |
| `NEW_WORKSPACE` | parent of this checkout | New parent directory for `Tcas/` and `infra/` |
| `BACKUP_DIR` | `<NEW_WORKSPACE>/backup` | Dumps and snapshots; outside both checkouts |
| `TCAS_URL` | old `PUBLIC_SERVER` | Final public species URL |
| `KEYCLOAK_PUBLIC_URL` | `<TCAS_URL>/keycloak` | Final public Keycloak base URL |
| `PORTAL_URL` | required | Multi-species portal origin |
| `NEW_HTTP_PORT` | `9092` | New species host port |
| `NEW_ES_PORT` | `9204` | New infra Elasticsearch host port |
| `NEW_PROJECT` | `tcas` | Compose project; must differ from the old one |
| `SPECIES_CODE`, `REALM`, `CLIENT_ID` | old `.env`, then `Tcas`, `ibb`, `ibb-client` | Species code, realm and client |
| `OLD_KEYCLOAK_ADMIN`, `OLD_KEYCLOAK_ADMIN_PASSWORD` | old `.env` | Override only if the old `.env` is stale |
| `ES_MODE` | `snapshot` | How indices move; see `migration.env.example` |
| `IMAGE_MODE` | `auto` | How images are shared or copied; see `migration.env.example` |
| `EMOBASE_WEB_IMAGE` | `ghcr.io/emobase/emobase-web:dev` | Web image; pin a release or SHA for a long-lived deployment |
| `OBA_IMAGE` | `jboss/base-jdk:7` | Java 7 image for the OBA jar |
| `SSL_CERT_FILE`, `SSL_CERT_KEY_FILE` | unset | Override the certificate paths for `apache-apply.sh` |

The old Compose project name, HTTP port and data paths are read from
`OLD_SPECIES_DIR/.env`; they are not set in `migration.env`. The new stack
reuses the old absolute `IMAGE_DIR` for the direct-NFS layout.

### Image paths

`IMAGE_MODE=auto` is the default. For the production direct-NFS layout it
reuses the old absolute `IMAGE_DIR` unchanged, so no image files are copied.

`imageservice` requires `/images/community-data` to be writable, so the NFS
export must be mounted read-write for the new stack.

`IMAGE_MODE=copy` is the fallback when the image source is read-only; it
materializes the images into the new `./images`.

## 3. Preflight check

```bash
./migrate.sh check
```

This step is read-only. It:

- checks required commands (`docker`, `git`, `rsync`, `curl`, `tar`, `python3`)
- verifies the old checkout and `.env`
- prints the old project, old `HTTP_PORT` and data paths
- checks that the old `PUBLIC_DATA_DIR`, `PRIVATE_DATA_DIR` and `IMAGE_DIR` exist and are readable
- detects the image layout and action, and checks that `community-data` is writable
- checks that old and new project names differ and paths do not overlap
- checks that the old `mysql`, `keycloak` and `es` services are running
- checks the old Directus volume and the new ports
- calls the portal READY endpoint
- in `snapshot` mode, checks the old Elasticsearch and `es_bk`
- warns if Keycloak admin credentials are missing

Then print the planned commands:

```bash
./migrate.sh --dry-run prepare
```

Do not run `prepare` if `check` fails. Fix the config and rerun.

### Dry-run safety

`--dry-run` is safe for every phase, including `transfer` and `rollback`: it
prints the Compose, `rsync`, `curl` and SQL operations instead of executing
them. It never stops a container or writes to the old checkout.

## 4. Prepare the new stack

```bash
./migrate.sh prepare
```

This phase neither copies data nor starts a container. It only prepares the
checkouts and configuration:

1. Clones `emobase-deploy` (if needed) and `emobase-infra`.
2. Writes `infra/.env` with the old MySQL root and Keycloak admin secrets, the
   final Keycloak URL and the ES port. It does not run the infra `init.sh` and
   does not start the stack; an existing `infra/.env` keeps its password.
3. Gives the old `es_bk` directory to UID `1000` (the Elasticsearch container)
   when `ES_MODE=snapshot`, so it can write the snapshot during `transfer`.
4. Writes the new species `.env` with the final `TCAS_URL` and
   `KEYCLOAK_PUBLIC_URL`.
5. Writes the image media override if needed.

After `prepare`:

- The old site is still serving on 443.
- Nothing new is running; no data has been copied.

## 5. Install the CLI and check the new configuration

`emobase` is the cross-repository control point for EMOBase. It checks the
configuration shared between `infra/` and `Tcas/`, and later records what
belongs to the new stack. Install it once:

```bash
curl -fsSL https://raw.githubusercontent.com/EMOBase/emobase-cli/main/install.sh | sh
```

See the [`emobase-cli` repository](https://github.com/EMOBase/emobase-cli) for
pinned releases, per-user installs and source builds.

Then validate the prepared workspace:

```bash
emobase --workspace <NEW_WORKSPACE> doctor
```

`emobase doctor` checks the new `infra/.env` and `Tcas/.env` against the shared
contract. Expect no errors and one warning, `workspace ownership ledger not
found`: do not run `emobase sync` or `emobase bootstrap` as it suggests, the
migration is in progress and the ledger is written after verification, in the
adoption step. Fix any other finding before `transfer`.

Then run `transfer` in the announced window; it starts the new infra and copies
the data.

## 6. Copy all data

```bash
./migrate.sh transfer
```

This is the only data copy. It runs while Apache still points at the old
stack, so the old application keeps serving reads. Writes made during this window may not be
carried over; announce that users should resubmit anything important.

It:

1. Ensures the old MySQL/Keycloak/ES are running.
2. Starts the new infra: MySQL first, verifies the root login, then Keycloak
   and Elasticsearch.
3. Dumps the final Directus and Keycloak databases.
4. Mirrors local files and the Directus uploads volume.
5. Takes/restores the Elasticsearch snapshot.
6. Runs `setup-directus` and starts the new stack on `9092`.

The old application is not stopped.

## 7. Configure Apache and verify

```bash
sudo ./apache-apply.sh --dry-run   # optional: print the vhost and the target
sudo ./apache-apply.sh             # generate, install, test and reload
```

It reads `migration.env`, detects the certificate, backs up the current
`*:443` vhost, installs the generated one, tests the configuration and reloads
Apache. If `configtest` fails it restores the backup and does not reload, so the
old site keeps running.

Verify:

```bash
./migrate.sh verify
```

Then open `<TCAS_URL>` and confirm:

- a real user signs in with the old password
- Directus content and uploads are present
- search, phenotypes, images, publications, GO annotations and ontology work
- JBrowse2 and BLAST open the portal release
- `/download/` files work

If anything fails, restore Apache and do not run `finish`; the old stack is
still running:

```bash
sudo ./apache-apply.sh --restore
```

If everything passes, stop the old stack:

```bash
./migrate.sh finish
```

Then continue with Adopt the workspace (section 9). Sections 8 and 9 are
alternatives, not consecutive steps.

## 8. Rolling back

Skip this step when everything is fine. If a problem appears after `finish`,
run:

```bash
./migrate.sh rollback
```

By default, this stops the new species and infra stacks, starts the old stack,
and prints the old Apache target. Their volumes are kept for a retry.

Use `./migrate.sh rollback --keep-new` to start the old stack but leave the new
species and infra stacks running. In that mode, the new app remains available
on `127.0.0.1:9092` for local diagnosis.

Restore the old 443 vhost and reload Apache:

```bash
sudo ./apache-apply.sh --restore
```

Pass `--backup FILE` to restore a different backup.

Confirm the old site, Keycloak login and Directus work. Do not run `cleanup`:
the old volumes are the rollback window and still hold the authoritative data.

The old MySQL/Keycloak/ES volumes and the old `directus` database were not
modified.

Rollback remains possible until the cleanup step removes the old volumes.

If you want to retry, fix the failure, run `check` again, then rerun the phase
that failed. The script re-copies the old data during `transfer`; new
writes made after Apache was repointed are not merged back automatically.

## 9. Adopt the workspace in `emobase-cli`

Run this only after the final verification passes. Do not run it after a
rollback; it applies to the new `tcas` stack.

Run the commands from `<NEW_WORKSPACE>`, the directory containing `infra/` and
`Tcas/`:

```bash
cd <NEW_WORKSPACE>

emobase status
emobase doctor --live
emobase sync --dry-run
emobase sync
```

- `emobase status` shows the running containers, shared URLs, MySQL databases
  and Keycloak realms.
- `emobase doctor --live` checks the cross-repo configuration and runtime
  probes; it exits non-zero on errors.
- `emobase sync --dry-run` prints the databases and realm origins that would be
  recorded, without changing anything.
- `emobase sync` records the existing database, realm and configured index
  prefix in `<NEW_WORKSPACE>/.emobase/state.json`, and registers any missing
  database or origin. It does not restart containers or rewrite `.env`.

`emobase sync` creates the ledger that the CLI check reported as missing;
rerun `emobase doctor --live` to confirm no state warning remains. After this,
the workspace can be managed with `emobase status`, `emobase up`, `emobase down`
and `emobase update`.

## 10. Retention and cleanup

Keep the old stack stopped, its volumes and `<BACKUP_DIR>` until the agreed
retention period. This is the rollback window.

After that, from the migration folder
(`<NEW_WORKSPACE>/Tcas/migrations/tcas-main-to-dev`), review the teardown plan:

```bash
./migrate.sh cleanup
```

This prints the commands and deletes nothing. To run them:

```bash
./migrate.sh cleanup --apply
```

`--apply` prints the plan again and requires the old project name to be typed;
it refuses `--yes`. It then stops the old Compose project and removes the old
MySQL, ES, BLAST, JBrowse2 and Directus volumes. It stops at the first failure,
skips volumes that no longer exist, and keeps `tcas_directus-data`, which the
new stack uses. It refuses to run while the new species stack is stopped.

The old checkout's `data/`, `images/` and `oba/` directories are not removed by
the script; `IMAGE_DIR` may be an external mount. Remove local directories
manually after the retention period if no longer needed.

Then delete this migration folder.

## Troubleshooting

- **`check` fails on a port**: the old stack owns `HTTP_PORT` from its `.env`
  (default `9090`) and `9202`; the new stack uses `9092`/`9204`. Stop the
  conflicting process or change `NEW_HTTP_PORT` / `NEW_ES_PORT` and the Apache
  examples.
- **Keycloak cannot start, `Access denied for user 'root'`**: the infra MySQL
  volume was initialized with a different password than `infra/.env`.
  `mysqladmin ping` still reports MySQL as healthy. Before `transfer` the new
  infra has no data, so recreate the volume:
  ```bash
  cd <NEW_WORKSPACE>/infra && docker compose down
  docker volume rm emobase-infra_mysql-data
  ```
- **Snapshot fails with `AccessDeniedException: /es-bk/...`**: the old
  Elasticsearch container runs as UID `1000` and cannot write the `es_bk` tree.
  `prepare` corrects the ownership; to do it by hand:
  `sudo chown -R 1000:0 <OLD_SPECIES_DIR>/es_bk`. Changing only the top
  directory (`chmod o+w es_bk`) is not enough, because the index subdirectories
  keep their owners.
- **`check` fails on `9092` or `9204`**: an earlier attempt left the new
  species or infra stack running. Stop it while keeping volumes, then rerun the
  phase:
  ```bash
  cd <NEW_WORKSPACE>/Tcas && docker compose down
  cd <NEW_WORKSPACE>/infra && docker compose down
  ```
- **Final URL login fails**: the 443 vhost is still pointing at the old stack,
  the `/keycloak` route is missing, or the Keycloak admin credentials are
  stale.
- **400 Bad Request, "Size of a request header field exceeds server limit"**:
  the browser is sending too many or too large cookies, often because old
  and new site cookies share the same host. Raise the Apache/nginx header
  limit (for example Apache `LimitRequestFieldSize 16384` or nginx
  `large_client_header_buffers 4 16k`) and clear site data for the host or use
  a fresh browser profile. There is no application-level guard:
  Apache rejects the request before it reaches the app. Optionally, set an
  Apache `ErrorDocument 400` page that tells users to clear site data; it
  improves the message but does not prevent the failure.
- **`apache-apply.sh` cannot detect the certificate**: it writes placeholders.
  Set `SSL_CERT_FILE` and `SSL_CERT_KEY_FILE` in `migration.env` and rerun
  `sudo ./apache-apply.sh`. Run the script as root: `/etc/ssl/private` is usually
  readable only by root.
- **Login ends at `/api/auth/error?error=Configuration`, `fe` log says
  `UNABLE_TO_VERIFY_LEAF_SIGNATURE` or `ENOTFOUND`**: the app container cannot
  reach `INTERNAL_KEYCLOAK_ISSUER`. Use
  `http://host.docker.internal:8181/keycloak/realms/<realm>` and recreate `fe`.
- **Keycloak admin login fails after the DB copy**: the copied master realm has
  the current admin password, not the old bootstrap password. Set the current
  admin in `migration.env` and rerun the phase that updates `infra/.env`.
- **Directus shows no uploads**: the `directus-data` mirror did not run, or the
  new project name is not `tcas`.
- **Search or ontology data is empty after transfer**: check the snapshot restore
  output. The snapshot path is the default; `rebuild` requires every service to
  have its source data.
- **Images fail or `imageservice` restarts with `community-data: Read-only file
  system`**: the image mount is read-only, or `community-data` is not writable
  by the `UID`/`GID` from the old `.env`. Fix the mount or permissions, or use
  `IMAGE_MODE=copy` so `community-data` stays local.
- **OBA keeps restarting**: set `OBA_IMAGE=jboss/base-jdk:7` (or another Java 7
  image known to run the OBA jar); Docker Hub removed the official `openjdk:7`
  image.
- **The host runs out of memory while both stacks are up**: stop optional old
  services (`oba`, `ontoscope`, `blast`, `geneservice`, `swagger-ui`,
  `querypipelineservice`) or lower the new infra ES heap/limit for the migration
  run. The script does not stop them by default.
- **JBrowse/BLAST missing**: the portal release is not READY, or
  `PORTAL_SERVER` is wrong.
- **Final URL still shows the old site**: the 443 vhost still points at the old
  `HTTP_PORT`; apply the final Apache block and reload.
