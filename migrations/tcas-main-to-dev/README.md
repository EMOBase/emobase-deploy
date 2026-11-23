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
| Compose project | existing value, usually `ibb` | `tcas` |
| Species site | `9090` | `9092` |
| Temporary Apache URL | — | `https://<TCAS_HOST>:9443` |
| Keycloak | legacy at `/ibb/keycloak` | infra at `/keycloak`, port `8181` |
| Elasticsearch | old stack, `9202` | infra, host port `9204` |
| Public URL | `<TCAS_URL>` until cutover | `<TCAS_URL>` after cutover |

The old checkout, project name, volumes and container names are not changed.
The new stack uses separate volumes and a separate Directus database.

## 1. Preconditions

Stop before changing anything if any of these is false.

- The portal has a READY Tcas release:

  ```bash
  curl -fsS "<PORTAL_URL>/api/genomicsservice/v1/public/versions?status=READY"
  ```

  The response must contain the Tcas assembly. Without it, the new site has no
  genomics, JBrowse2 or BLAST data.

- The current Keycloak admin credentials are available. They are either in the
  old `.env` (`KEYCLOAK_ADMIN`, `KEYCLOAK_ADMIN_PASSWORD`) or will be supplied
  in `migration.env`. The copied database keeps the current admin account.

- The old Keycloak is 24.0.3, matching `emobase-infra`. Do not use a database
  copy across different Keycloak versions.

- The infra Keycloak does not already host other realms. Replacing its
  `keycloak` database wipes those realms.

- There is enough disk and time for a full copy of `data/`, `images/`,
  `oba/`, the Directus uploads volume, MySQL dumps and an Elasticsearch
  rebuild.

- Docker/Compose access is available, and Apache can be edited and reloaded.

- Ports `9092` (new species), `9204` (new infra ES) and `8181` (new infra
  Keycloak) are free.

- The old checkout uses the default `./data`, `./images` and `./oba` paths.

- The old `mysql`, `keycloak` and `es` services are running, and the old
  Directus volume exists.

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
| `ES_MODE` | `rebuild`; the snapshot path is manual |
| `DEPLOY_REPO`, `INFRA_REPO` | Git URLs |
| `EMOBASE_WEB_IMAGE` | Pin a release or SHA for a long-lived deployment |

The old Compose project name is read from `OLD_SPECIES_DIR/.env`; it is not set
in `migration.env`.

## 3. Validate without changing anything

```bash
./migrate.sh check
```

This step is read-only. It:

- checks required commands (`docker`, `git`, `rsync`, `curl`, `tar`, `python3`)
- verifies the old checkout and `.env`
- checks that old and new project names differ and paths do not overlap
- checks that the old `mysql`, `keycloak` and `es` services are running
- checks the old Directus volume and the new ports
- calls the portal READY endpoint
- warns if Keycloak admin credentials are missing

Then print the planned commands:

```bash
./migrate.sh --dry-run prepare
```

Do not run `prepare` if `check` fails. Fix the config and rerun.

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
   - `KEYCLOAK_PUBLIC_URL=<TCAS_URL>/keycloak`, realm `ibb`, client
     `ibb-client`
   - `DIRECTUS_DB_DATABASE=directus_tcas`
   - `EMOBASE_ES_INDEX_PREFIX=tcas`
   - old `DIRECTUS_SECRET`, Directus admin, `SSR_OIDC_SESSION_SECRET`,
     Keycloak client secret and COCO values
   - `COMPOSE_PROJECT_NAME=tcas`

3. Copies `data/`, `images/` and `oba/` from the old checkout into the new
   one. The old files are read only.

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

- The old site is still serving on `9090` / `<TCAS_URL>`.
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

5. Mirrors `data/`, `images/`, `oba/` and the Directus uploads volume again, so
   the new stack has the final files.

6. Runs `setup-directus` against the final database.

7. Deletes the new `tcas-*` Elasticsearch indices and starts the new services,
   which rebuild the indices from the final `data/private` and `images`.

8. Stops the old MySQL/Keycloak/ES containers. Their volumes remain intact for
   rollback.

After `delta`:

- The old stack is stopped, but its volumes are untouched.
- The new stack is running on `9092` with final data.
- Reopen `https://<TCAS_HOST>:9443`, sign in and recheck the data before
  cutover.
- Do not clean up anything.

If a service does not rebuild its indices, stop and use the snapshot fallback
described in section 11.

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

Until this proxy change is applied, `<TCAS_URL>` still reaches the old `9090`
stack, even though the new `.env` already says `<TCAS_URL>`.

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

This stops the new stack, starts the old stack, and prints the old Apache
target. Restore the old 443 vhost:

```text
/        -> 127.0.0.1:9090
/ibb/keycloak through the old stack
```

The old MySQL/Keycloak/ES volumes and the old `directus` database were not
modified. Directus writes made on the new stack after cutover live only in
`directus_tcas` and the new volumes; those writes are not copied back.

Rollback remains possible until the cleanup step removes the old volumes.

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

## 11. Snapshot fallback for Elasticsearch

The default `ES_MODE=rebuild` lets the species services rebuild `tcas-*` from
the copied data. If a service does not rebuild, use a snapshot instead of
copying the old `es-data` volume.

1. On the old ES (`9202`), register a repository and take a snapshot.
2. Copy the old `es_bk` directory to `infra/es_bk`.
3. Register the repository on the new infra ES (`9204`).
4. Restore with `rename_pattern "(.+)"`, `rename_replacement "tcas-$1"` and
   `include_aliases: false`.
5. Check `_cat/indices` and document counts.

Do not copy the old `es-data` volume between Elasticsearch versions.

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

The old checkout's `data/` and `images/` directories are not removed by the
script. Remove those directories manually after the retention period if no
longer needed.

Then delete this migration folder.

## Troubleshooting

- **`check` fails on a port**: the old stack owns `9090`/`9202`; the new stack
  uses `9092`/`9204`. Stop the conflicting process or change `NEW_HTTP_PORT` /
  `NEW_ES_PORT` and the Apache examples.
- **Staging login fails**: the staging origin is missing, the 443 `/keycloak`
  route is missing, or the Keycloak admin credentials are stale.
- **Keycloak admin login fails after the DB copy**: the copied master realm has
  the current admin password, not the old bootstrap password. Set the current
  admin in `migration.env` and rerun the phase that updates `infra/.env`.
- **Directus shows no uploads**: the `directus-data` mirror did not run, or the
  new project name is not `tcas`.
- **Search is empty after delta**: the services did not rebuild; wait for
  startup or use the snapshot fallback.
- **JBrowse/BLAST missing**: the portal release is not READY, or
  `PORTAL_SERVER` is wrong.
- **Final URL still shows the old site**: the 443 vhost still points at
  `9090`; apply the final Apache block and reload.
