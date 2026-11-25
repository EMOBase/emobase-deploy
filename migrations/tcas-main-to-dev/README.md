# Migrating Tcas from `main` to `dev`

> **One-time production migration.** Delete this folder after the migration is
> verified.
>
> This is not a fresh deployment. It copies live data, replaces the infra
> Keycloak database and briefly stops the old site. Read the whole runbook
> before running any command, and do not continue past a failed checkpoint.

This runbook migrates the running Tcas deployment to the `dev` layout with
`emobase-infra`, while keeping the old stack available for rollback.

The migration is parallel:

| | Old stack | New stack |
| --- | --- | --- |
| Compose project | `COMPOSE_PROJECT_NAME` from old `.env` (default `ibb`) | `tcas` |
| Species site | `HTTP_PORT` from old `.env` (default `9090`) | `9092` |
| Temporary Apache URL | — | `https://<TCAS_HOST>:9443` |
| Keycloak | legacy at `/ibb/keycloak` | infra at `/keycloak`, port `8181`; on 9443 during migration, 443 after cutover |
| Elasticsearch | old stack, `9202` | infra, host port `9204` |
| Public URL | `<TCAS_URL>` until cutover | `<TCAS_URL>` after cutover |

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

- The old Keycloak is 24.0.3, matching `emobase-infra`. Do not use a database
  copy across different Keycloak versions.

- There is enough local disk for the two checkouts (`emobase-deploy` on `dev`
  and `emobase-infra`) and the local copies (`data/private`, `oba/`, the
  Directus uploads volume, MySQL dumps and the Elasticsearch snapshot).

- The old data paths in `.env` exist and are readable. `PUBLIC_DATA_DIR` and
  `IMAGE_DIR` may be absolute external mounts.

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

It asks for the old checkout, workspace, backup directory, URLs, ports and
names, then writes `migration.env`. Press Enter to accept a default. To change
values later, edit `migration.env` or rerun `./migrate.sh init --force`.

`migration.env` is ignored by git. The values are:

| Variable | Meaning |
| --- | --- |
| `OLD_SPECIES_DIR` | Existing running Tcas checkout; read-only |
| `NEW_WORKSPACE` | New parent directory for `Tcas/` and `infra/` |
| `BACKUP_DIR` | Backups and phase dumps; outside both checkouts |
| `TCAS_URL` | Final public species URL |
| `MIGRATION_URL` | Temporary migration URL, `https://<TCAS_HOST>:9443` |
| `PORTAL_URL` | Deployed multi-species portal |
| `KEYCLOAK_PUBLIC_URL` | Final Keycloak URL; during migration `MIGRATION_URL/keycloak` is used |
| `SSL_CERT_FILE`, `SSL_CERT_KEY_FILE` | Optional Apache certificate overrides; otherwise `apache` detects them |
| `NEW_HTTP_PORT` | `9092` |
| `NEW_ES_PORT` | `9204` |
| `NEW_PROJECT` | `tcas`; must differ from the old project |
| `SPECIES_CODE`, `REALM`, `CLIENT_ID` | `Tcas`, `ibb`, `ibb-client` |
| `OLD_KEYCLOAK_ADMIN`, `OLD_KEYCLOAK_ADMIN_PASSWORD` | Override only if the old `.env` is stale |
| `ES_MODE` | `snapshot`; takes a fresh old-cluster snapshot and restores it. `rebuild` is only for deployments that can rebuild every index |
| `IMAGE_MODE` | `auto` (recommended); `copy` is the fallback when the image source is read-only |
| `EMOBASE_WEB_IMAGE` | Pin a release or SHA for a long-lived deployment |
| `OBA_IMAGE` | `jboss/base-jdk:7`; the old server needed this because `openjdk:7` does not run the OBA jar |

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

## 3. Validate without changing anything

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

`--dry-run` is safe for every phase, including `delta` and `rollback`: it
prints the Compose, `rsync`, `curl` and SQL operations instead of executing
them. It never stops a container or writes to the old checkout.

## 4. Prepare the new stack (old site stays live)

```bash
./migrate.sh prepare
```

This phase does not stop the old application and does not change the old
checkout. It performs these actions in order.

1. Clones `emobase-infra` into `<NEW_WORKSPACE>/infra` if missing, writes its
   `.env` with `KEYCLOAK_PUBLIC_URL` and `ELASTICSEARCH_HOST_PORT=9204`, and
   starts it. Infra Keycloak uses `8181`; ES uses `9204`, away from the old
   `9202`.

2. Writes `<NEW_WORKSPACE>/Tcas/.env`:
   - project `tcas`, site port `9092`, migration URL `9443`
   - `PORTAL_SERVER` and `INTERNAL_API_GENOMICS_SERVICE`
   - `PUBLIC_DATA_DIR` and `PRIVATE_DATA_DIR` taken from the old `.env`
   - `IMAGE_DIR` for the detected image layout; direct NFS reuses the absolute
     path
   - `KEYCLOAK_PUBLIC_URL=<TCAS_URL>/keycloak`, realm `ibb`, client
     `ibb-client`
   - `DIRECTUS_DB_DATABASE=directus_tcas`
   - `EMOBASE_ES_INDEX_PREFIX=tcas`
   - old `DIRECTUS_SECRET`, Directus admin, `SSR_OIDC_SESSION_SECRET`,
     Keycloak client secret and COCO values
   - `COMPOSE_PROJECT_NAME=tcas`
   - `OBA_IMAGE` from `migration.env`

3. Reuses or materializes the image directory according to `IMAGE_MODE`, and
   copies local `data/` and `oba/`.

4. Mirrors the old `<OLD_PROJECT>_directus-data` volume into
   `tcas_directus-data`.

5. Dumps the old `directus` database, drops/recreates `directus_tcas` in infra
   MySQL, and imports the dump. The old `directus` database is not modified.

6. Checks that the infra Keycloak has no realms other than `master` and `ibb`,
   then replaces the **infra** Keycloak database with a dump of the old
   `keycloak` database. It also writes the old current admin credentials into
   `infra/.env` and restarts infra Keycloak. This is the step that preserves
   users, password hashes, OTP data and the `ibb` client.

7. Adds `<TCAS_URL>` and `<MIGRATION_URL>` as Keycloak origins.

8. Runs `setup-directus` against the imported database.

9. Starts the new species stack on `9092` and prints migration URL checks.

After `prepare`:

- The old site is still serving on `HTTP_PORT` from the old `.env` (default
  `9090`) / `<TCAS_URL>`.
- The new site is running on `9092`, but not yet reachable through Apache.
- Do not run `delta` yet.

## 5. Expose and smoke-test the migration URL

This is a pre-cutover smoke test, not the final data check. It catches login,
Apache and Keycloak routing problems while the old site is still live.

The old site owns 443. The new site and its Keycloak use a temporary 9443
vhost, so the old 443 vhost is not edited before cutover.

`prepare` configures the new site and infra Keycloak with
`KEYCLOAK_PUBLIC_URL=https://<TCAS_HOST>:9443/keycloak`. At cutover, both move
to `https://<TCAS_HOST>/keycloak`.

Apache applies `ProxyPass` in order, so the `/keycloak` line must come before
the `/` catch-all.

1. Generate the vhosts:

   ```bash
   ./migrate.sh apache
   ```

   It writes `<NEW_WORKSPACE>/apache-migration.conf` and
   `<NEW_WORKSPACE>/apache-final.conf`, using the host from `TCAS_URL` and the
   detected certificate paths. If detection fails, set `SSL_CERT_FILE` and
   `SSL_CERT_KEY_FILE` in `migration.env`. The files follow
   `apache-migration.conf.example` and `apache-final.conf.example`.

2. Install the migration vhost and reload Apache:

   ```bash
   cp <NEW_WORKSPACE>/apache-migration.conf \
      /etc/apache2/sites-available/tcas-migration.conf
   a2ensite tcas-migration
   apachectl configtest
   systemctl reload apache2
   ```

3. Open `https://<TCAS_HOST>:9443` and verify:
   - one real user signs in with the old password
   - the new site loads and Directus content/uploads from the initial copy are
     present
   - images and `/download/` files work
   - OBA and Ontoscope start if used
   - JBrowse2 and BLAST links point at the portal

Search, GO annotation, ontology and publication results may be empty until
`delta` restores the Elasticsearch snapshot. They are checked again after
`delta` and at the final verification.

If login fails, check the Keycloak admin credentials and the migration origin.
Do not run `delta` until this checkpoint passes.

## 6. Delta: freeze, copy final data, restart the new stack

```bash
./migrate.sh delta
```

This is the maintenance-window step. The old site is unavailable from the
moment the old application containers stop until the final Apache switch.

What it does, in order:

1. Stops all old application containers. The old MySQL, Keycloak and ES
   services are started again for the exports.

2. Stops the new species stack so nothing writes to the new database or
   Directus volume during the copy.

3. Dumps the final old `directus` database, drops/recreates `directus_tcas`,
   and imports it. This replaces the initial prepare copy.

4. Stops the old Keycloak, dumps the final `keycloak` database, replaces the
   infra Keycloak database again, restores the admin credentials in
   `infra/.env`, restarts infra Keycloak, and re-adds both origins. This keeps
   users created or changed during the migration.

5. Mirrors the local `data/` and `oba/` directories and the Directus uploads
   volume again, so the new stack has the final files. The NFS image directory
   is reused, not copied.

6. Runs `setup-directus` against the final database.

7. Takes a fresh snapshot of the old Elasticsearch and copies `es_bk` into
   `infra/es_bk`. It then deletes the new `tcas-*` indices, registers the
   snapshot repository on the new infra ES, and restores the old indices with
   the `tcas-` prefix. The default `ES_MODE=snapshot` preserves ontology, GO
   annotation and publication data that cannot be rebuilt from `data/private`.

8. Starts the new services, then stops the old MySQL/Keycloak/ES containers.
   Their volumes remain intact for rollback.

After `delta`:

- The old stack is stopped, but its volumes are untouched.
- The new stack is running on `9092` with final data.
- Reopen `https://<TCAS_HOST>:9443`, sign in and recheck the data before
  cutover.
- Do not clean up anything.

If a service does not show its data, check the snapshot restore result and the
new index names before continuing.

## 7. Cut over the final URL

First move the application and Keycloak to the final URL:

```bash
./migrate.sh cutover
```

This sets `PUBLIC_SERVER=<TCAS_URL>` and
`KEYCLOAK_PUBLIC_URL=<TCAS_URL>/keycloak` in the new `.env`, moves the infra
Keycloak to the same public URL, restarts Keycloak and the species stack, and
re-adds the final origin. It does **not** edit Apache. The Keycloak issuer
changes, so existing test sessions may need a fresh login. Keycloak is already
on 443 at this point, so the 9443 site cannot log in until the final 443 vhost
is applied.

Then replace the `<VirtualHost *:443>` block with
`<NEW_WORKSPACE>/apache-final.conf` (generated by `./migrate.sh apache`). It is
the migration vhost on 443; 443 is already in `ports.conf`, so there is no
`Listen 443`. Reload Apache:

```bash
apachectl configtest
systemctl reload apache2
```

Until this proxy change is applied, `<TCAS_URL>` still reaches the old
`HTTP_PORT` stack (default `9090`), even though the new `.env` already says
`<TCAS_URL>`. If you changed `NEW_HTTP_PORT` from `9092`, regenerate the
vhosts with `./migrate.sh apache`.

Remove the temporary `9443` vhost only after the final verification passes.

## 8. Verify the final URL

```bash
./migrate.sh verify
```

This checks:

- the old nginx is stopped and the new stack is running
- `<TCAS_URL>` is reachable
- `<TCAS_URL>/ibb/directus` is reachable
- the Keycloak realm is reachable at `<TCAS_URL>/keycloak`

Then open `<TCAS_URL>` and confirm:

- a real user signs in with the old password
- Directus content and uploads are present
- search, phenotypes, images, publications, GO annotations and ontology work
- JBrowse2 and BLAST open the portal release
- `/download/` files work

## 9. Rolling back

Run this only if the final verification failed, or if the cutover is
intentionally abandoned. Do not run it after a successful migration.

```bash
./migrate.sh rollback
```

This stops the new species stack, starts the old stack, and prints the old
Apache target. The new infra stack (MySQL, Keycloak, ES) is not stopped; it
does not serve the public site and can stay up for diagnosis or a retry. If
cutover already moved Keycloak to 443, rollback moves it back to the migration
URL.

Restore the old 443 vhost:

```text
/        -> 127.0.0.1:<OLD_HTTP_PORT>   # default 9090
/ibb/keycloak through the old stack
```

If you added a temporary `9443` vhost, remove or disable it. Then reload Apache
and verify the old site:

```bash
apachectl configtest
systemctl reload apache2
```

Confirm the old site, Keycloak login and Directus work. Do not run `cleanup`:
the old volumes are the rollback window and still hold the authoritative data.

The old MySQL/Keycloak/ES volumes and the old `directus` database were not
modified. Directus writes made on the new stack after cutover live only in
`directus_tcas` and the new volumes; those writes are not copied back.

Rollback remains possible until the cleanup step removes the old volumes.
If you want to retry, fix the failure, run `check` again, then rerun the phase
that failed. The script re-copies the old data during `prepare`/`delta`; new
writes made after cutover are not merged back automatically.

## 10. Adopt the workspace in `emobase-cli`

Run this only after the final verification passes. Do not run it after a
rollback; it applies to the new `tcas` stack.

`emobase-cli` is the cross-repository control point for EMOBase. It discovers
the `infra/` and `Tcas/` checkouts, validates the configuration shared between
them, and records which database, realm and Elasticsearch index prefix belong
to which checkout. It does not migrate data; it is for operating and monitoring
the new stack.

Install the CLI:

```bash
curl -fsSL https://raw.githubusercontent.com/EMOBase/emobase-cli/main/install.sh | sh
emobase --version
```

See the [`emobase-cli` repository](https://github.com/EMOBase/emobase-cli) for
pinned releases, per-user installs and source builds.

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

If `doctor` reports `state.unrecorded`, running `sync` resolves it. After this,
the workspace can be managed with `emobase status`, `emobase up`, `emobase down`
and `emobase update`.

## 11. Elasticsearch snapshot restore

`ES_MODE=snapshot` is the default and the recommended path for this migration.
The old deployment's `data/private` directories are empty, and the ontology, GO
annotation and publication services have no local data mounts, so they cannot
rebuild every index from files. The script takes a fresh snapshot of the old
cluster during `delta` and restores it into the new infra ES with the `tcas-`
index prefix. It prints `_cat/indices` so you can check names and document
counts.

Do not copy the old `es-data` volume between Elasticsearch versions.

Use `ES_MODE=rebuild` only after verifying that every service rebuilds its own
indices from the copied data. The old host's existing
`full_backup_<date>` snapshot is not a substitute for the fresh snapshot taken
during `delta`.

## 12. Retention and cleanup

Keep the old stack stopped, its volumes and `<BACKUP_DIR>` until the agreed
retention period. This is the rollback window.

After that, print the destructive commands:

```bash
./migrate.sh cleanup
```

The output stops the old Compose project and removes the old MySQL, ES, BLAST,
JBrowse2 and Directus volumes. It keeps `tcas_directus-data`, which the new
stack uses. The commands are printed only; review and run those commands manually.

The old checkout's `data/`, `images/` and `oba/` directories are not removed by
the script. Remove local directories manually after the retention period if no
longer needed.

Then delete this migration folder.

## Troubleshooting

- **`check` fails on a port**: the old stack owns `HTTP_PORT` from its `.env`
  (default `9090`) and `9202`; the new stack uses `9092`/`9204`. Stop the
  conflicting process or change `NEW_HTTP_PORT` / `NEW_ES_PORT` and the Apache
  examples.
- **`check` fails on `9092` or `9204` after `prepare`**: the new species or
  infra stack is still running. Stop it while keeping volumes, then rerun
  `prepare`:
  ```bash
  cd <NEW_WORKSPACE>/Tcas && docker compose down
  cd <NEW_WORKSPACE>/infra && docker compose down
  ```
- **Migration URL login fails**: the migration origin is missing, the 443 `/keycloak`
  route is missing, or the Keycloak admin credentials are stale.
- **Keycloak admin login fails after the DB copy**: the copied master realm has
  the current admin password, not the old bootstrap password. Set the current
  admin in `migration.env` and rerun the phase that updates `infra/.env`.
- **Directus shows no uploads**: the `directus-data` mirror did not run, or the
  new project name is not `tcas`.
- **Search or ontology data is empty after delta**: check the snapshot restore
  output. The snapshot path is the default; `rebuild` requires every service to
  have its source data.
- **Images fail or `imageservice` restarts with `community-data: Read-only file
  system`**: the image mount is read-only, or `community-data` is not writable
  by the `UID`/`GID` from the old `.env`. Fix the mount or permissions, or use
  `IMAGE_MODE=copy` so `community-data` stays local.
- **OBA keeps restarting**: set `OBA_IMAGE=jboss/base-jdk:7` (or another image
  known to run the OBA jar); `openjdk:7` does not work on the test server.
- **The host runs out of memory while both stacks are up**: stop optional old
  services (`oba`, `ontoscope`, `blast`, `geneservice`, `swagger-ui`,
  `querypipelineservice`) or lower the new infra ES heap/limit for the migration
  run. The script does not stop them by default.
- **JBrowse/BLAST missing**: the portal release is not READY, or
  `PORTAL_SERVER` is wrong.
- **Final URL still shows the old site**: the 443 vhost still points at the old
  `HTTP_PORT`; apply the final Apache block and reload.
