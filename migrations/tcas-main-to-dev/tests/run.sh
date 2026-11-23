#!/usr/bin/env bash
#
# Local, Docker-free checks for migrate.sh.
#
# This builds a synthetic old checkout and a synthetic new workspace, stubs
# docker and curl, and verifies:
#   - check reads HTTP_PORT/project/data paths from the old .env
#   - an external PUBLIC_DATA_DIR is reused, never copied
#   - images symlinks are preserved
#   - dry-run prepare/delta/rollback never execute mutating commands
#   - prepare writes the expected new .env
#
# It does not talk to any server and does not require a Docker daemon.

set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../migrate.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tcas-migrate-test.XXXXXX")"
MOCK_LOG="$TMP/mock.log"
export MOCK_LOG
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }
contains() { printf '%s' "$1" | grep -Fq -- "$2" || fail "expected output to contain: $2"; }
not_contains() { if printf '%s' "$1" | grep -Fq -- "$2"; then fail "output unexpectedly contains: $2"; fi; }

# ---------------------------------------------------------------- fixtures

mkdir -p "$TMP/old/data/private/imageservice" \
         "$TMP/old/data/private/phenotypeservice" \
         "$TMP/old/data/public" \
         "$TMP/old/images/community-data" \
         "$TMP/old/oba" \
         "$TMP/old/es_bk/indices" \
         "$TMP/external/tcas5" \
         "$TMP/external/images" \
         "$TMP/new/Tcas/.git" \
         "$TMP/new/infra/.git" \
         "$TMP/new/infra/scripts" \
         "$TMP/new/backup" \
         "$TMP/bin"

printf 'private-image\n' > "$TMP/old/data/private/imageservice/keep"
printf 'private-phenotype\n' > "$TMP/old/data/private/phenotypeservice/keep"
printf 'public-local\n' > "$TMP/old/data/public/keep"
printf 'community\n' > "$TMP/old/images/community-data/keep"
printf 'oba\n' > "$TMP/old/oba/oba-server.jar"
printf 'snapshot\n' > "$TMP/old/es_bk/indices/keep"
printf '424GB-style external file\n' > "$TMP/external/tcas5/public-file.txt"
printf 'image\n' > "$TMP/external/images/1"
ln -s "$TMP/external/images/1" "$TMP/old/images/1"

cat > "$TMP/old/compose.yml" <<'EOF'
services:
  mysql: {}
  keycloak: {}
  es: {}
  nginx: {}
EOF
cat > "$TMP/old/compose.tcas.yml" <<'EOF'
services:
  oba: {}
EOF

cat > "$TMP/old/.env" <<EOF
COMPOSE_PROJECT_NAME=testold
HTTP_PORT=6092
PUBLIC_SERVER=https://old.test
PUBLIC_DATA_DIR=$TMP/external/tcas5
PRIVATE_DATA_DIR=./data/private
IMAGE_DIR=./images
UID=1003
GID=1003
KEYCLOAK_ADMIN=admin
KEYCLOAK_ADMIN_PASSWORD=old-admin-password
MYSQL_ROOT_PASSWORD=old-mysql-password
DIRECTUS_SECRET=old-directus-secret
DIRECTUS_ADMIN_EMAIL=admin@example.org
DIRECTUS_ADMIN_PASSWORD=old-directus-password
KEYCLOAK_CLIENT_SECRET=old-client-secret
SSR_OIDC_SESSION_SECRET=old-ssr-secret
COCO_USERNAME=coco
COCO_PASSWORD=old-coco-password
EOF

cat > "$TMP/new/infra/.env" <<'EOF'
MYSQL_ROOT_PASSWORD=new-infra-mysql-password
KEYCLOAK_ADMIN=admin
KEYCLOAK_ADMIN_PASSWORD=new-infra-admin-password
EOF

cat > "$TMP/new/Tcas/compose.yml" <<'EOF'
services: {}
EOF
cat > "$TMP/new/Tcas/compose.tcas.yml" <<'EOF'
services: {}
EOF

cat > "$TMP/new/infra/scripts/allow-origin.sh" <<'EOF'
#!/usr/bin/env bash
printf 'allow-origin %s\n' "$*" >> "${MOCK_LOG:-/dev/null}"
EOF
chmod +x "$TMP/new/infra/scripts/allow-origin.sh"

cat > "$TMP/migration.env" <<EOF
OLD_SPECIES_DIR=$TMP/old
NEW_WORKSPACE=$TMP/new
BACKUP_DIR=$TMP/new/backup
TCAS_URL=https://tcas.test
STAGING_URL=https://tcas.test:9443
PORTAL_URL=https://portal.test
KEYCLOAK_PUBLIC_URL=https://tcas.test/keycloak
NEW_HTTP_PORT=19092
NEW_ES_PORT=19204
NEW_PROJECT=tcastest
SPECIES_CODE=Tcas
REALM=ibb
CLIENT_ID=ibb-client
OLD_KEYCLOAK_ADMIN=admin
OLD_KEYCLOAK_ADMIN_PASSWORD=old-admin-password
ES_MODE=snapshot
DEPLOY_REPO=https://example.invalid/emobase-deploy.git
INFRA_REPO=https://example.invalid/emobase-infra.git
EMOBASE_WEB_IMAGE=ghcr.io/emobase/emobase-web:test
OBA_IMAGE=jboss/base-jdk:7
EOF

cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
log() { printf '%s\n' "$*" >> "${MOCK_LOG:-/dev/null}"; }
if [[ "${1:-}" == "compose" && "${2:-}" == "version" ]]; then
  echo "Docker Compose version v2.0.0"
  exit 0
fi
if [[ "${1:-}" == "volume" && "${2:-}" == "inspect" ]]; then
  exit 0
fi
if [[ "${1:-}" == "volume" && "${2:-}" == "create" ]]; then
  log "volume create ${3:-}"
  exit 0
fi
if [[ "${1:-}" == "run" ]]; then
  log "docker run $*"
  exit 0
fi
if [[ "${1:-}" == "compose" ]]; then
  case " $* " in
    *" ps "*)
      if [[ "$*" == *" -f "* ]]; then
        printf 'mysql\nkeycloak\nes\n'
      else
        printf 'nginx\n'
      fi
      exit 0
      ;;
    *" up "*|*" stop "*|*" down "*)
      log "compose $*"
      exit 0
      ;;
    *" exec "*|*" run "*)
      exit 0
      ;;
  esac
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/bin/docker"

cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$*" in
  *"/api/genomicsservice/v1/public/versions"*)
    printf '{"data":[]}\n'
    ;;
  *"/_cat/indices"*)
    printf 'index docs.count store.size\n'
    ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/curl"

export PATH="$TMP/bin:$PATH"

run() {
  local name=$1
  shift
  local out
  if ! out=$(bash "$SCRIPT" --config "$TMP/migration.env" "$@" 2>&1); then
    printf '%s\n' "$out" >&2
    fail "$name exited non-zero"
  fi
  printf '%s' "$out"
}

reset_mock_log() { : > "$MOCK_LOG"; }
mock_has_mutations() {
  [[ -s "$MOCK_LOG" ]] && grep -Eq 'compose .*(up|stop|down)|volume create|docker run' "$MOCK_LOG"
}

# ---------------------------------------------------------------- tests
#
# Every test uses the stub docker in $TMP/bin. Tests labelled "without
# --dry-run" exercise the code path that issues Docker commands; the stub
# records those commands instead of touching real containers.

pass "syntax"
bash -n "$SCRIPT"

pass "help"
out=$(run help --help)
contains "$out" "Usage:"

pass "check reads old environment"
reset_mock_log
out=$(run check check)
contains "$out" "old project: testold"
contains "$out" "old HTTP port: 6092"
contains "$out" "old public data: $TMP/external/tcas5"
contains "$out" "reused, not copied"
contains "$out" "PUBLIC_DATA_DIR is external"
contains "$out" "new project: tcastest"
! mock_has_mutations || fail "check executed a mutating command"

pass "dry-run prepare never copies public data"
reset_mock_log
out=$(run "dry-run prepare" --dry-run prepare)
contains "$out" "+ rsync -a"
contains "$out" "would write"
contains "$out" "would ask: Replace the infra Keycloak database"
not_contains "$out" "rsync -a $TMP/external/tcas5"
! mock_has_mutations || fail "dry-run prepare executed a mutating command"
[[ ! -e "$TMP/new/Tcas/data" ]] || fail "dry-run prepare created data/"

pass "dry-run delta does not stop the old stack"
reset_mock_log
cat > "$TMP/new/Tcas/.env" <<'EOF'
PUBLIC_SERVER=https://tcas.test:9443
EOF
out=$(run "dry-run delta" --dry-run delta)
contains "$out" "+ cd $TMP/old && docker compose"
contains "$out" "snapshot"
contains "$out" "_restore"
! mock_has_mutations || fail "dry-run delta executed a mutating command"

pass "dry-run rollback does not execute stop"
reset_mock_log
out=$(run "dry-run rollback" --dry-run rollback)
contains "$out" "Restore the old Apache configuration"
contains "$out" "127.0.0.1:6092"
! mock_has_mutations || fail "dry-run rollback executed a mutating command"

pass "dry-run cleanup only prints"
reset_mock_log
out=$(run "dry-run cleanup" cleanup)
contains "$out" "docker volume rm"
! mock_has_mutations || fail "cleanup executed a mutating command"

pass "prepare writes the expected env and preserves external paths"
reset_mock_log
rm -f "$TMP/new/Tcas/.env"
out=$(run prepare --yes prepare)
envfile="$TMP/new/Tcas/.env"
[[ -f "$envfile" ]] || fail "prepare did not write .env"
contains "$(cat "$envfile")" "COMPOSE_PROJECT_NAME=tcastest"
contains "$(cat "$envfile")" "HTTP_PORT=19092"
contains "$(cat "$envfile")" "PUBLIC_DATA_DIR=$TMP/external/tcas5"
contains "$(cat "$envfile")" "PRIVATE_DATA_DIR=./data/private"
contains "$(cat "$envfile")" "IMAGE_DIR=./images"
contains "$(cat "$envfile")" "PUBLIC_SERVER=https://tcas.test:9443"
contains "$(cat "$envfile")" "KEYCLOAK_PUBLIC_URL=https://tcas.test/keycloak"
contains "$(cat "$envfile")" "OBA_IMAGE=jboss/base-jdk:7"
contains "$(cat "$envfile")" "COMPOSE_FILE=compose.yml:compose.tcas.yml"

[[ -f "$TMP/new/Tcas/data/private/imageservice/keep" ]] || fail "private data was not copied"
[[ -f "$TMP/new/Tcas/data/private/phenotypeservice/keep" ]] || fail "private phenotype data was not copied"
[[ -f "$TMP/new/Tcas/oba/oba-server.jar" ]] || fail "oba was not copied"
[[ -f "$TMP/new/Tcas/images/community-data/keep" ]] || fail "community-data was not copied"
[[ -L "$TMP/new/Tcas/images/1" ]] || fail "images/1 is not a symlink"
[[ "$(readlink "$TMP/new/Tcas/images/1")" == "$TMP/external/images/1" ]] || fail "images/1 symlink target changed"
[[ ! -e "$TMP/new/Tcas/public-file.txt" ]] || fail "external public data was copied"
[[ ! -e "$TMP/new/Tcas/data/tcas5" ]] || fail "external public directory was copied"

pass "rollback without --dry-run issues stop and up"
reset_mock_log
out=$(run rollback --yes rollback)
contains "$out" "Restore the old Apache configuration"
contains "$out" "127.0.0.1:6092"
grep -Fq "compose stop" "$MOCK_LOG" || fail "rollback did not issue stop for the new stack"
grep -Fq "compose -f compose.yml -f compose.tcas.yml up -d --wait" "$MOCK_LOG" \
  || fail "rollback did not issue up for the old stack"

pass "all tests passed"
