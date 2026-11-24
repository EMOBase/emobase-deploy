# Migrating Tcas from `main` to `dev`

> **One-time production migration.** Delete this folder after the migration is
> verified.
>
> This is not a fresh deployment. It copies live data, replaces the infra
> Keycloak database and briefly stops the old site. Read the whole step before
> running its command, and do not continue past a failed checkpoint.

This runbook migrates the running Tcas deployment to the `dev` layout with
`emobase-infra`, while keeping the old stack available for rollback.

The migration is parallel:

| | Old stack | New stack |
| --- | --- | --- |
| Compose project | `COMPOSE_PROJECT_NAME` from old `.env` (default `ibb`) | `tcas` |
| Species site | `HTTP_PORT` from old `.env` (default `9090`) | `9092` |
| Temporary Apache URL | — | `https://<TCAS_HOST>:9443` |
| Keycloak | legacy at `/ibb/keycloak` | infra at `/keycloak`, port `8181` |
| Elasticsearch | old stack, `9202` | infra, host port `9204` |
| Public URL | `<TCAS_URL>` until cutover | `<TCAS_URL>` after cutover |

The old checkout, project name, volumes and container names are not changed.
The new stack uses separate volumes and a separate Directus database.

The script reads the old project name, old HTTP port and data paths from
`OLD_SPECIES_DIR/.env`. Do not hardcode a staging clone's values into the
runbook: a clone may use a different `HTTP_PORT`, project name or mount path
than the real server.

> **Safety rule for `PUBLIC_DATA_DIR`.** It may be an absolute external mount,
> as on the test server, where it is a 424 GB read-only NFS export. The script
> reuses that path read-only in the new `.env` and never copies it. Copying it
> would duplicate hundreds of gigabytes and is never part of this migration.

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
  Keycloak) are free. The old site keeps using `HTTP_PORT` from its `.env`;
  do not assume it is `9090`.

- The old `mysql`, `keycloak` and `es` services are running, and the old
  Directus volume exists.

- On a memory-constrained test host, the old and new stacks must fit at the
  same time. The script warns but does not stop optional old services; the
  fallback is described in Troubleshooting.

## 2. Get the new checkout and configure

Clone the target `dev` checkout:

```bash
mkdir -p <NEW_WORKSPACE>
git clone --branch dev https://github.com/EMOBase/emobase-deploy.git <NEW_WORKSPACE>/Tcas
cd <NEW_WORKSPACE>/Tcas/migrations/tcas-main-to-dev
```

The script runs from this checkout. It reads the old checkout from
`OLD_SPECIES_DIR` and clones `emobase-infra` itself.

Copy and edit the config:

```bash
cp migration.env.example migration.env
${EDITOR:-vi} migration.env
```

`migration.env` is ignored by git. Fill in:

| Variable | Meaning |
| --- | --- |
| `OLD_SPECIES_DIR` | Existing running Tcas checkout; read-only |
| `NEW_WORKSPACE` | New parent directory for `Tcas/` and `infra/` |
| `BACKUP_DIR` | Backups and phase dumps; outside both checkouts |
| `TCAS_URL` | Final public species URL |
| `STAGING_URL` | Temporary URL, `https://<TCAS_HOST>:9443` |
| `PORTAL_URL` | Deployed multi-species portal |
| `KEYCLOAK_PUBLIC_URL` | `<TCAS_URL>/keycloak` |
| `NEW_HTTP_PORT` | `9092` |
| `NEW_ES_PORT` | `9204` |
| `NEW_PROJECT` | `tcas`; must differ from the old project |
| `SPECIES_CODE`, `REALM`, `CLIENT_ID` | `Tcas`, `ibb`, `ibb-client` |
| `OLD_KEYCLOAK_ADMIN`, `OLD_KEYCLOAK_ADMIN_PASSWORD` | Override only if the old `.env` is stale |
| `ES_MODE` | `snapshot`; takes a fresh old-cluster snapshot and restores it. `rebuild` is only for deployments that can rebuild every index |
| `IMAGE_MODE` | `auto` (detect the old layout), `copy` (materialize image files), or `mount` (force symlink-farm mode). See “Image paths” below |
| `IMAGE_MOUNT_SOURCE` | Host path to mount in `mount` mode. Leave empty to derive it from the old `IMAGE_DIR` symlinks |
| `DEPLOY_REPO`, `INFRA_REPO` | Git URLs |
| `EMOBASE_WEB_IMAGE` | Pin a release or SHA for a long-lived deployment |
| `OBA_IMAGE` | `jboss/base-jdk:7`; the old server needed this because `openjdk:7` does not run the OBA jar |

The old Compose project name, HTTP port, `PUBLIC_DATA_DIR`, `PRIVATE_DATA_DIR`
and `IMAGE_DIR` are read from `OLD_SPECIES_DIR/.env`; they are not set in
`migration.env`. The new stack uses `IMAGE_DIR=./images` for local layouts, or
reuses the old absolute `IMAGE_DIR` for the direct-NFS layout.

### Image paths

`IMAGE_MODE=auto` is the default and detects the old layout:

| Old image layout | Detected layout | New stack |
| --- | --- | --- |
| absolute `IMAGE_DIR`, e.g. `/media/ibeetleb/images` | `direct` | reuse the same absolute path; no copy |
| `./images` symlink to NFS/directory | `whole-symlink` | new `images` is a symlink to the same target |
| `./images` NFS bind mount | `whole-mount` | new `images` is a symlink to the mount point |
| directory of absolute symlinks | `symlink-farm` | preserve symlinks; generate `compose.media.yml` |
| real directory of files | `real-files` | copy the files |

Docker bind mounts do not resolve absolute symlinks from a symlink farm inside a
container. The symlink target must also be mounted at the same absolute path.

`IMAGE_MODE=mount` forces the symlink-farm behavior. It writes
`<NEW_WORKSPACE>/Tcas/compose.media.yml`, which bind-mounts
`IMAGE_MOUNT_SOURCE` read-only at the same absolute path in `imageservice` and
`phenotypeservice`. The local `./images/community-data` stays writable. It is
not valid for a real-file directory.

`IMAGE_MODE=copy` copies the real 3.9 GB of images into the new `./images`,
following symlinks. It is the fallback when the source image path is unavailable
or read-only.

`imageservice` requires `/images/community-data` to be writable. For a
whole-NFS layout, `community-data` is on NFS and must be writable; for the
symlink-farm layout it stays local. If a whole-NFS target is read-only, use
`IMAGE_MODE=copy` or a writable overlay.

Never set `IMAGE_DIR` directly to a read-only NFS path: `imageservice` fails at
startup trying to create `/images/community-data`.

## 3. Validate without changing anything

```bash
./migrate.sh check
```

This step is read-only. It:

- checks required commands (`docker`, `git`, `rsync`, `curl`, `tar`, `python3`)
- verifies the old checkout and `.env`
- prints the old project, old `HTTP_PORT` and data paths
- checks that the old `PUBLIC_DATA_DIR`, `PRIVATE_DATA_DIR` and `IMAGE_DIR` exist and are readable
- warns when `PUBLIC_DATA_DIR` is an external mount and will be reused read-only
- detects and prints the image layout (`whole-symlink`, `whole-mount`,
  `symlink-farm`, `real-files`) and action (`link`, `mount`, `copy`)
- validates the target or `IMAGE_MOUNT_SOURCE` and checks that the service's
  `community-data` is writable
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
them. It never stops a container, writes to the old checkout or copies
`PUBLIC_DATA_DIR`.

The script never writes under `OLD_SPECIES_DIR`. It refuses to copy paths
outside the old checkout, and it reuses an external `PUBLIC_DATA_DIR` in the
new `.env` instead of copying it. `cleanup` only prints commands; it does not
run them.

`tests/run.sh` is a local, Docker-free mock harness. It builds a synthetic old
checkout, stubs `docker` and `curl`, and verifies that `check` reads the old
environment, that dry-run phases do not mutate anything, and that `prepare`
handles both image modes.

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
   - project `tcas`, site port `9092`, staging URL `9443`
   - `PORTAL_SERVER` and `INTERNAL_API_GENOMICS_SERVICE`
   - `PUBLIC_DATA_DIR` and `PRIVATE_DATA_DIR` copied from the old `.env`; an
     absolute external `PUBLIC_DATA_DIR` is reused, not copied
   - `IMAGE_DIR=./images`; `IMAGE_MODE` decides whether those are real files or
     symlinks plus a compose override
   - `KEYCLOAK_PUBLIC_URL=<TCAS_URL>/keycloak`, realm `ibb`, client
     `ibb-client`
   - `DIRECTUS_DB_DATABASE=directus_tcas`
   - `EMOBASE_ES_INDEX_PREFIX=tcas`
   - old `DIRECTUS_SECRET`, Directus admin, `SSR_OIDC_SESSION_SECRET`,
     Keycloak client secret and COCO values
   - `COMPOSE_PROJECT_NAME=tcas`
   - `OBA_IMAGE` from `migration.env`

3. Handles image storage according to `IMAGE_MODE` and the detected layout:
   - absolute `IMAGE_DIR` (direct NFS): reuses the same absolute path;
   - whole symlink/mount: links the new `images` directory to the same target;
   - symlink farm: preserves symlinks and writes `compose.media.yml`;
   - real files or `copy`: materializes images into the new `./images`.
   It also copies local `data/` and `oba/`. An external `PUBLIC_DATA_DIR` is
   not copied.

4. Mirrors the old `<OLD_PROJECT>_directus-data` volume into
   `tcas_directus-data`.

5. Dumps the old `directus` database, drops/recreates `directus_tcas` in infra
   MySQL, and imports the dump. The old `directus` database is not modified.

6. Asks for confirmation, then replaces the **infra** Keycloak database with a
   dump of the old `keycloak` database. It also writes the old current admin
   credentials into `infra/.env` and restarts infra Keycloak. This is the step
   that preserves users, password hashes, OTP data and the `ibb` client.

7. Adds `<TCAS_URL>` and `<STAGING_URL>` as Keycloak origins.

8. Runs `setup-directus` against the imported database.

9. Starts the new species stack on `9092` and prints staging checks.

After `prepare`:

- The old site is still serving on `HTTP_PORT` from the old `.env` (default
  `9090`) / `<TCAS_URL>`.
- The new site is running on `9092`, but not yet reachable through Apache.
- Do not run `delta` yet.

## 5. Expose and verify staging

The new site needs an HTTPS URL so browser login can be tested. It also needs
the existing 443 vhost to route `/keycloak` to infra.

1. Add the `/keycloak` route to the 443 vhost. This must come before the
   species catch-all:

   ```apache
   ProxyPreserveHost On
   RequestHeader set X-Forwarded-Proto "https"
   ProxyPass        /keycloak  http://127.0.0.1:8181/keycloak
   ProxyPassReverse /keycloak  http://127.0.0.1:8181/keycloak
   ```

2. Add the staging vhost from `apache-staging.conf.example`:

   ```apache
   Listen 9443
   <VirtualHost *:9443>
       ServerName <TCAS_HOST>
       SSLEngine on
       SSLCertificateFile    /path/fullchain.pem
       SSLCertificateKeyFile /path/privkey.pem
       ProxyPreserveHost On
       RequestHeader set X-Forwarded-Proto "https"
       ProxyPass        /  http://127.0.0.1:9092/
       ProxyPassReverse /  http://127.0.0.1:9092/
   </VirtualHost>
   ```

3. Check and reload Apache:

   ```bash
   apachectl configtest
   systemctl reload apache2
   ```

4. Open `https://<TCAS_HOST>:9443` and verify:
   - one real user signs in with the old password
   - Directus content and uploads are present
   - search, phenotypes, images, publications, GO annotations and ontology work
   - OBA and Ontoscope work if used
   - `/download/` files work
   - JBrowse2 and BLAST links point at the portal

If login fails, check the Keycloak admin credentials and the staging origin.
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
   users created or changed during staging.

5. Mirrors the local `data/`, `images/` and `oba/` directories and the
   Directus uploads volume again, so the new stack has the final files. An
   external `PUBLIC_DATA_DIR` is reused read-only and is not copied.

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

First update the new application configuration:

```bash
./migrate.sh cutover
```

This sets `PUBLIC_SERVER=<TCAS_URL>` in the new `.env`, restarts the species
stack, and re-adds the final Keycloak origin. It does **not** edit Apache.

Then change the 443 vhost:

```apache
ProxyPreserveHost On
RequestHeader set X-Forwarded-Proto "https"

ProxyPass        /keycloak  http://127.0.0.1:8181/keycloak
ProxyPassReverse /keycloak  http://127.0.0.1:8181/keycloak

ProxyPass        /  http://127.0.0.1:9092/
ProxyPassReverse /  http://127.0.0.1:9092/
```

`apache-final.conf.example` is the same block. Reload Apache:

```bash
apachectl configtest
systemctl reload apache2
```

Until this proxy change is applied, `<TCAS_URL>` still reaches the old
`HTTP_PORT` stack (default `9090`), even though the new `.env` already says
`<TCAS_URL>`. If you changed `NEW_HTTP_PORT` from `9092`, use that value in the
Apache block and in the staging vhost.

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
does not serve the public site and can stay up for diagnosis or a retry.

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
rebuild every index from files. A fresh snapshot is taken during `delta` and
restored into the new infra ES.

The script automates this:

1. On the old ES (`9202`), register repository `ibb` at `/es-bk` and take a
   fresh snapshot named `migration-<timestamp>`.
2. Copy the old `es_bk` directory to `infra/es_bk`.
3. Register repository `ibb` on the new infra ES (`9204`).
4. Delete the new `tcas-*` indices.
5. Restore the old indices with `rename_pattern "(.+)"`,
   `rename_replacement "tcas-$1"`, `include_aliases: false` and
   `include_global_state: false`. The old `geneservice-*` indices are excluded;
   the new site gets genomics, JBrowse2 and BLAST data from the portal.
6. Print `_cat/indices` so you can check names and document counts.

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
the script. An external `PUBLIC_DATA_DIR` (for example a read-only NFS mount)
is never removed or copied by this runbook. Remove local directories manually
after the retention period if no longer needed.

Then delete this migration folder.

## Troubleshooting

- **`check` fails on a port**: the old stack owns `HTTP_PORT` from its `.env`
  (default `9090`) and `9202`; the new stack uses `9092`/`9204`. Stop the
  conflicting process or change `NEW_HTTP_PORT` / `NEW_ES_PORT` and the Apache
  examples.
- **Staging login fails**: the staging origin is missing, the 443 `/keycloak`
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
  system`**: the new stack is pointing `IMAGE_DIR` at an external read-only
  mount. Use `IMAGE_MODE=copy`, or keep `IMAGE_MODE=mount` and ensure
  `compose.media.yml` is in `COMPOSE_FILE`. The image service also needs
  `/images/community-data` to be writable.
- **Image URLs return 500 or a small text body instead of a JPEG**: check
  `imageservice` logs and whether `/images/<filepath>` resolves inside the
  container. Absolute symlinks from `./images` into `/media/ibeetleb/images`
  require that target to be mounted at the same absolute path.
- **OBA keeps restarting**: set `OBA_IMAGE=jboss/base-jdk:7` (or another image
  known to run the OBA jar); `openjdk:7` does not work on the test server.
- **The host runs out of memory while both stacks are up**: stop optional old
  services (`oba`, `ontoscope`, `blast`, `geneservice`, `swagger-ui`,
  `querypipelineservice`) or lower the new infra ES heap/limit for the staging
  run. The script does not stop them by default.
- **JBrowse/BLAST missing**: the portal release is not READY, or
  `PORTAL_SERVER` is wrong.
- **Final URL still shows the old site**: the 443 vhost still points at the old
  `HTTP_PORT`; apply the final Apache block and reload.
