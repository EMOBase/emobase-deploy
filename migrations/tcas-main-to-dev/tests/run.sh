#!/usr/bin/env bash
#
# Local, Docker-free checks for migrate.sh.
#
# This builds a synthetic old checkout and a synthetic new workspace, stubs
# docker and curl, and verifies:
#   - init writes a config and refuses to overwrite without --force
#   - check reads HTTP_PORT/project/data paths from the old .env
#   - an external PUBLIC_DATA_DIR is reused, never copied
#   - image copy and mount modes both work
#   - dry-run prepare/transfer/rollback never execute mutating commands
#   - prepare writes the expected new .env, fixes es_bk ownership and starts
#     nothing
#   - transfer starts the infra before copying data
#   - cleanup prints by default; --apply needs the old project name
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
chmod 777 "$TMP/old/images/community-data"
printf 'oba\n' > "$TMP/old/oba/oba-server.jar"
printf 'snapshot\n' > "$TMP/old/es_bk/indices/keep"
printf '424GB-style external file\n' > "$TMP/external/tcas5/public-file.txt"
printf 'image\n' > "$TMP/external/images/1"
printf 'cert\n' > "$TMP/cert.pem"
printf 'key\n' > "$TMP/key.pem"
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
PORTAL_URL=https://portal.test/
KEYCLOAK_PUBLIC_URL=https://tcas.test/keycloak
SSL_CERT_FILE=$TMP/cert.pem
SSL_CERT_KEY_FILE=$TMP/key.pem
NEW_HTTP_PORT=19092
NEW_ES_PORT=19204
NEW_PROJECT=tcastest
SPECIES_CODE=Tcas
REALM=ibb
CLIENT_ID=ibb-client
OLD_KEYCLOAK_ADMIN=admin
OLD_KEYCLOAK_ADMIN_PASSWORD=old-admin-password
ES_MODE=snapshot
IMAGE_MODE=copy
IMAGE_MOUNT_SOURCE=
DEPLOY_REPO=https://example.invalid/emobase-deploy.git
INFRA_REPO=https://example.invalid/emobase-infra.git
EMOBASE_WEB_IMAGE=ghcr.io/emobase/emobase-web:test
OBA_IMAGE=jboss/base-jdk:7
EOF

cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
log() { printf '%s %s\n' "$PWD" "$*" >> "${MOCK_LOG:-/dev/null}"; }
if [[ "${1:-}" == "compose" && "${2:-}" == "version" ]]; then
  echo "Docker Compose version v2.0.0"
  exit 0
fi
if [[ "${1:-}" == "volume" && "${2:-}" == "inspect" ]]; then
  case " ${MOCK_VOLUME_MISSING:-} " in
    *" ${3:-} "*) exit 1 ;;
  esac
  exit 0
fi
if [[ "${1:-}" == "volume" && "${2:-}" == "rm" ]]; then
  log "volume rm ${3:-}"
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
if [[ "${1:-}" == "exec" ]]; then
  log "docker exec $*"
  exit 0
fi
if [[ "${1:-}" == "compose" ]]; then
  case " $* " in
    *" ps "*)
      if [[ -n "${MOCK_PS_EMPTY:-}" ]]; then
        exit 0
      fi
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
    *"REALM WHERE NAME NOT IN"*)
      printf '%s\n' "${MOCK_KEYCLOAK_EXTRA_REALMS:-0}"
      exit 0
      ;;
    *" exec "*"mysql"*)
      if [[ -n "${MOCK_MYSQL_DENIED:-}" ]]; then
        printf 'ERROR 1045 (28000): Access denied for user '\''root'\''\n' >&2
        exit 1
      fi
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

run_cfg() {
  local name=$1 cfg=$2
  shift 2
  local out
  if ! out=$(bash "$SCRIPT" --config "$cfg" "$@" 2>&1); then
    printf '%s\n' "$out" >&2
    fail "$name exited non-zero"
  fi
  printf '%s' "$out"
}

run() {
  local name=$1
  shift
  run_cfg "$name" "$TMP/migration.env" "$@"
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

pass "init writes a config"
init_cfg="$TMP/init.env"
init_out=$(OLD_SPECIES_DIR="$TMP/old" NEW_WORKSPACE="$TMP/init-workspace" \
  TCAS_URL="https://tcas.init" PORTAL_URL="https://portal.init" \
  bash "$SCRIPT" --config "$init_cfg" init --yes 2>&1)
[[ -f "$init_cfg" ]] || fail "init did not write a config"
init_content=$(cat "$init_cfg")
old_abs=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$TMP/old")
ws_abs=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$TMP/init-workspace")
contains "$init_content" "OLD_SPECIES_DIR=$old_abs"
contains "$init_content" "NEW_WORKSPACE=$ws_abs"
contains "$init_content" "KEYCLOAK_PUBLIC_URL=https://tcas.init/keycloak"
contains "$init_content" "NEW_PROJECT=tcas"
contains "$init_out" "Next:"

pass "init strips trailing slashes from URLs"
trim_cfg="$TMP/init-trim.env"
OLD_SPECIES_DIR="$TMP/old" NEW_WORKSPACE="$TMP/init-trim" \
  TCAS_URL="https://tcas.init//" KEYCLOAK_PUBLIC_URL="https://auth.init/keycloak/" \
  PORTAL_URL="https://portal.init/" \
  bash "$SCRIPT" --config "$trim_cfg" init --yes >/dev/null 2>&1
contains "$(cat "$trim_cfg")" "TCAS_URL=https://tcas.init"
contains "$(cat "$trim_cfg")" "KEYCLOAK_PUBLIC_URL=https://auth.init/keycloak"
contains "$(cat "$trim_cfg")" "PORTAL_URL=https://portal.init"

pass "init defaults the Tcas URL from the old .env"
url_cfg="$TMP/init-url.env"
OLD_SPECIES_DIR="$TMP/old" NEW_WORKSPACE="$TMP/init-workspace" \
  PORTAL_URL="https://portal.init" \
  bash "$SCRIPT" --config "$url_cfg" init --yes >/dev/null 2>&1
contains "$(cat "$url_cfg")" "TCAS_URL=https://old.test"
contains "$(cat "$url_cfg")" "KEYCLOAK_PUBLIC_URL=https://old.test/keycloak"

pass "init does not overwrite without --force"
if OLD_SPECIES_DIR="$TMP/old" NEW_WORKSPACE="$TMP/init-workspace" \
  TCAS_URL="https://other.init" PORTAL_URL="https://portal.init" \
  bash "$SCRIPT" --config "$init_cfg" init --yes >/dev/null 2>&1; then
  fail "init overwrote an existing config"
fi
contains "$(cat "$init_cfg")" "TCAS_URL=https://tcas.init"

pass "init --force overwrites"
OLD_SPECIES_DIR="$TMP/old" NEW_WORKSPACE="$TMP/init-workspace" \
  TCAS_URL="https://other.init" PORTAL_URL="https://portal.init" \
  bash "$SCRIPT" --config "$init_cfg" init --yes --force >/dev/null 2>&1
contains "$(cat "$init_cfg")" "TCAS_URL=https://other.init"

pass "init --dry-run does not write"
dry_cfg="$TMP/init-dry.env"
dry_out=$(OLD_SPECIES_DIR="$TMP/old" NEW_WORKSPACE="$TMP/init-workspace" \
  TCAS_URL="https://tcas.init" PORTAL_URL="https://portal.init" \
  bash "$SCRIPT" --config "$dry_cfg" init --yes --dry-run 2>&1)
[[ ! -e "$dry_cfg" ]] || fail "init --dry-run wrote a config"
contains "$dry_out" "would write"

pass "apache generates the final vhost with the configured certificate"
out=$(run apache apache)
fin="$TMP/new/apache-final.conf"
[[ -f "$fin" ]] || fail "apache did not write the final vhost"
contains "$(cat "$fin")" "ServerName tcas.test"
contains "$(cat "$fin")" "SSLCertificateFile    $TMP/cert.pem"
contains "$(cat "$fin")" "ProxyPass        /keycloak"
contains "$(cat "$fin")" "LimitRequestFieldSize 16384"
contains "$(cat "$fin")" "127.0.0.1:19092"
contains "$(cat "$fin")" "<VirtualHost *:443>"
not_contains "$(cat "$fin")" "Listen 443"
contains "$out" "back up the active *:443 vhost"

pass "apache accepts an explicit root-only key path"
rootkey_cfg="$TMP/apache-rootkey.env"
sed "s#^SSL_CERT_KEY_FILE=.*#SSL_CERT_KEY_FILE=$TMP/missing-key.pem#" \
  "$TMP/migration.env" > "$rootkey_cfg"
if ! out=$(bash "$SCRIPT" --config "$rootkey_cfg" apache 2>&1); then
  printf '%s\n' "$out" >&2
  fail "apache rejected an explicit key path"
fi
contains "$out" "not visible"
contains "$(cat "$TMP/new/apache-final.conf")" "missing-key.pem"

pass "apache writes placeholders when no certificate is detected"
noplaceholder_cfg="$TMP/apache-nocert.env"
sed -e 's#^TCAS_URL=.*#TCAS_URL=https://no-cert.invalid#' \
    -e 's#^SSL_CERT_FILE=.*#SSL_CERT_FILE=#' \
    -e 's#^SSL_CERT_KEY_FILE=.*#SSL_CERT_KEY_FILE=#' \
    "$TMP/migration.env" > "$noplaceholder_cfg"
if ! out=$(bash "$SCRIPT" --config "$noplaceholder_cfg" apache 2>&1); then
  printf '%s\n' "$out" >&2
  fail "apache failed to generate placeholder vhosts"
fi
contains "$out" "using placeholders"
contains "$(cat "$TMP/new/apache-final.conf")" "/path/fullchain.pem"

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

pass "dry-run prepare does not copy data"
reset_mock_log
out=$(run "dry-run prepare" --dry-run prepare)
contains "$out" "would write"
not_contains "$out" "rsync -a $TMP/external/tcas5"
! mock_has_mutations || fail "dry-run prepare executed a mutating command"
! grep -Fq "chown -R 1000:0 /es-bk" "$MOCK_LOG" \
  || fail "dry-run prepare changed the es_bk ownership"
[[ ! -e "$TMP/new/Tcas/data" ]] || fail "dry-run prepare created data/"

pass "dry-run transfer does not stop the old stack"
reset_mock_log
cat > "$TMP/new/Tcas/.env" <<'EOF'
PUBLIC_SERVER=https://tcas.test
EOF
out=$(run "dry-run transfer" --dry-run transfer)
contains "$out" "+ cd $TMP/old && docker compose"
contains "$out" "snapshot"
contains "$out" "_restore"
! mock_has_mutations || fail "dry-run transfer executed a mutating command"

pass "dry-run rollback does not execute stop"
reset_mock_log
out=$(run "dry-run rollback" --dry-run rollback)
contains "$out" "Restore the old 443 vhost"
contains "$out" "127.0.0.1:6092"
! mock_has_mutations || fail "dry-run rollback executed a mutating command"

pass "cleanup only prints by default"
reset_mock_log
out=$(run "dry-run cleanup" cleanup)
contains "$out" "Nothing is deleted"
contains "$out" "cleanup --apply"
contains "$out" "docker volume rm"
! mock_has_mutations || fail "cleanup executed a mutating command"

pass "cleanup refuses --yes"
reset_mock_log
if out=$(bash "$SCRIPT" --config "$TMP/migration.env" --yes cleanup 2>&1); then
  fail "cleanup accepted --yes"
fi
contains "$out" "--yes is not valid with cleanup"
! mock_has_mutations || fail "refused cleanup still mutated"

pass "cleanup --apply needs the old project name"
reset_mock_log
if out=$(printf 'wrong\n' | bash "$SCRIPT" --config "$TMP/migration.env" cleanup --apply 2>&1); then
  fail "cleanup accepted a wrong project name"
fi
contains "$out" "cancelled"
! mock_has_mutations || fail "cancelled cleanup still mutated"

pass "cleanup --apply stops the old stack and removes old volumes"
reset_mock_log
out=$(printf 'testold\n' | bash "$SCRIPT" --config "$TMP/migration.env" cleanup --apply 2>&1) \
  || fail "cleanup --apply failed"
grep -Fq "compose -f compose.yml -f compose.tcas.yml down" "$MOCK_LOG" \
  || fail "cleanup did not stop the old stack"
grep -Fq "volume rm testold_mysql-data" "$MOCK_LOG" \
  || fail "cleanup did not remove the old mysql volume"
grep -Fq "volume rm testold_directus-data" "$MOCK_LOG" \
  || fail "cleanup did not remove the old directus volume"
if grep -Fq "volume rm tcastest_" "$MOCK_LOG"; then
  fail "cleanup removed a new-stack volume"
fi

pass "cleanup skips missing volumes"
reset_mock_log
out=$(printf 'testold\n' | MOCK_VOLUME_MISSING=testold_es-data \
  bash "$SCRIPT" --config "$TMP/migration.env" cleanup --apply 2>&1) \
  || fail "cleanup failed on a missing volume"
contains "$out" "skip testold_es-data (missing)"
if grep -Fq "volume rm testold_es-data" "$MOCK_LOG"; then
  fail "cleanup tried to remove a missing volume"
fi

pass "cleanup --apply refuses when the new stack is down"
reset_mock_log
if out=$(printf 'testold\n' | MOCK_PS_EMPTY=1 \
  bash "$SCRIPT" --config "$TMP/migration.env" cleanup --apply 2>&1); then
  fail "cleanup ran while the new stack was down"
fi
contains "$out" "not running"
! mock_has_mutations || fail "refused cleanup still mutated"

pass "prepare writes the expected env without data"
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
contains "$(cat "$envfile")" "PUBLIC_SERVER=https://tcas.test"
contains "$(cat "$envfile")" "PORTAL_SERVER=https://portal.test"
contains "$(cat "$envfile")" "INTERNAL_API_GENOMICS_SERVICE=https://portal.test/api/genomicsservice/v1"
contains "$(cat "$envfile")" "KEYCLOAK_PUBLIC_URL=https://tcas.test/keycloak"
contains "$(cat "$envfile")" "INTERNAL_KEYCLOAK_ISSUER=https://tcas.test/keycloak/realms/ibb"
contains "$(cat "$envfile")" "INTERNAL_DIRECTUS_URL=http://directus:8055"
contains "$(cat "$TMP/new/infra/.env")" "KEYCLOAK_PUBLIC_URL=https://tcas.test/keycloak"
contains "$(cat "$envfile")" "OBA_IMAGE=jboss/base-jdk:7"
contains "$(cat "$envfile")" "COMPOSE_FILE=compose.yml:compose.tcas.yml"
[[ ! -e "$TMP/new/Tcas/data" ]] || fail "prepare copied data"
! mock_has_mutations || fail "prepare started a container"
grep -Fq "chown -R 1000:0 /es-bk" "$MOCK_LOG" \
  || fail "prepare did not fix the es_bk ownership"

pass "transfer starts the infra and then copies data"
reset_mock_log
out=$(run "transfer" --yes transfer)
grep -Fq "/new/infra compose compose up -d --wait" "$MOCK_LOG" \
  || fail "transfer did not start the new infra"
[[ -f "$TMP/new/Tcas/data/private/imageservice/keep" ]] || fail "private data was not copied"
[[ -f "$TMP/new/Tcas/data/private/phenotypeservice/keep" ]] || fail "private phenotype data was not copied"
[[ -f "$TMP/new/Tcas/oba/oba-server.jar" ]] || fail "oba was not copied"
[[ -f "$TMP/new/Tcas/images/community-data/keep" ]] || fail "community-data was not copied"
[[ -f "$TMP/new/Tcas/images/1" && ! -L "$TMP/new/Tcas/images/1" ]] || fail "copy mode did not materialize images/1"
[[ "$(cat "$TMP/new/Tcas/images/1")" == "image" ]] || fail "copy mode image content is wrong"
[[ ! -e "$TMP/new/Tcas/public-file.txt" ]] || fail "external public data was copied"
[[ ! -e "$TMP/new/Tcas/data/tcas5" ]] || fail "external public directory was copied"
[[ ! -e "$TMP/new/Tcas/compose.media.yml" ]] || fail "copy mode wrote compose.media.yml"

# ---------------------------------------------------------------- infra init cwd
pass "prepare resets an existing env to the final URLs"
out=$(run "prepare rerun" --yes prepare)
contains "$(cat "$envfile")" "PUBLIC_SERVER=https://tcas.test"
contains "$(cat "$envfile")" "KEYCLOAK_PUBLIC_URL=https://tcas.test/keycloak"
contains "$(cat "$TMP/new/infra/.env")" "KEYCLOAK_PUBLIC_URL=https://tcas.test/keycloak"

pass "transfer refuses an infra Keycloak with other realms"
if out=$(MOCK_KEYCLOAK_EXTRA_REALMS=1 bash "$SCRIPT" --config "$TMP/migration.env" transfer 2>&1); then
  fail "transfer replaced a shared infra Keycloak"
fi
contains "$out" "refusing to replace its database"

pass "prepare writes infra/.env from the old secrets"
mkdir -p "$TMP/new-init/Tcas/.git" \
         "$TMP/new-init/infra/.git" \
         "$TMP/new-init/backup"
cp "$TMP/new/Tcas/compose.yml" "$TMP/new-init/Tcas/compose.yml"
cp "$TMP/new/Tcas/compose.tcas.yml" "$TMP/new-init/Tcas/compose.tcas.yml"
sed -e "s#^NEW_WORKSPACE=.*#NEW_WORKSPACE=$TMP/new-init#" \
    -e "s#^BACKUP_DIR=.*#BACKUP_DIR=$TMP/new-init/backup#" \
    "$TMP/migration.env" > "$TMP/migration-init.env"
if ! out=$(cd "$TMP" && bash "$SCRIPT" --config "$TMP/migration-init.env" --yes prepare 2>&1); then
  printf '%s\n' "$out" >&2
  fail "prepare failed when the infra .env was missing"
fi
init_env="$TMP/new-init/infra/.env"
[[ -f "$init_env" ]] || fail "prepare did not write infra/.env"
contains "$(cat "$init_env")" "MYSQL_ROOT_PASSWORD=old-mysql-password"
contains "$(cat "$init_env")" "KEYCLOAK_ADMIN=admin"
contains "$(cat "$init_env")" "KEYCLOAK_ADMIN_PASSWORD=old-admin-password"
contains "$(cat "$init_env")" "KEYCLOAK_PUBLIC_URL=https://tcas.test/keycloak"
contains "$(cat "$init_env")" "ELASTICSEARCH_HOST_PORT=19204"
contains "$(cat "$init_env")" "EMOBASE_INFRA_NETWORK=emobase-infra"
contains "$(cat "$TMP/new-init/Tcas/.env")" "MYSQL_ROOT_PASSWORD=old-mysql-password"
[[ ! -e "$TMP/.env" ]] || fail "prepare wrote .env in the working directory"

pass "prepare keeps an existing infra password"
out=$(run "prepare rerun" --yes prepare)
contains "$(cat "$TMP/new/infra/.env")" "MYSQL_ROOT_PASSWORD=new-infra-mysql-password"

pass "transfer stops when the infra MySQL password does not match the volume"
reset_mock_log
if out=$(MOCK_MYSQL_DENIED=1 bash "$SCRIPT" --config "$TMP/migration.env" --yes transfer 2>&1); then
  fail "transfer continued with an unusable infra MySQL password"
fi
contains "$out" "initialized with a different root password"
contains "$out" "emobase-infra_mysql-data"
if grep -Fq "compose stop" "$MOCK_LOG"; then
  fail "transfer stopped the new species stack before checking MySQL"
fi

# ---------------------------------------------------------------- mount mode
mkdir -p "$TMP/new-mount/Tcas/.git" \
         "$TMP/new-mount/infra/.git" \
         "$TMP/new-mount/infra/scripts" \
         "$TMP/new-mount/backup"

cp "$TMP/new/infra/.env" "$TMP/new-mount/infra/.env"
cp "$TMP/new/infra/scripts/allow-origin.sh" "$TMP/new-mount/infra/scripts/allow-origin.sh"
chmod +x "$TMP/new-mount/infra/scripts/allow-origin.sh"
cp "$TMP/new/Tcas/compose.yml" "$TMP/new-mount/Tcas/compose.yml"
cp "$TMP/new/Tcas/compose.tcas.yml" "$TMP/new-mount/Tcas/compose.tcas.yml"

sed \
  -e "s#^NEW_WORKSPACE=.*#NEW_WORKSPACE=$TMP/new-mount#" \
  -e "s#^BACKUP_DIR=.*#BACKUP_DIR=$TMP/new-mount/backup#" \
  -e "s#^IMAGE_MODE=.*#IMAGE_MODE=mount#" \
  -e "s#^IMAGE_MOUNT_SOURCE=.*#IMAGE_MOUNT_SOURCE=$TMP/external/images#" \
  "$TMP/migration.env" > "$TMP/migration-mount.env"

pass "default image mode auto-detects a symlink farm"
grep -v '^IMAGE_MODE=' "$TMP/migration.env" > "$TMP/migration-default.env"
reset_mock_log
out=$(run_cfg "default mode check" "$TMP/migration-default.env" check)
contains "$out" "image mode: auto"
contains "$out" "image layout: symlink-farm"
contains "$out" "image action: mount"
contains "$out" "bind-mount"
! mock_has_mutations || fail "default mode check executed a mutating command"

pass "check derives the mount source from symlinks"
sed 's#^IMAGE_MOUNT_SOURCE=.*#IMAGE_MOUNT_SOURCE=#' \
  "$TMP/migration-mount.env" > "$TMP/migration-mount-derived.env"
reset_mock_log
out=$(run_cfg "mount-derived check" "$TMP/migration-mount-derived.env" check)
contains "$out" "image mode: mount"
contains "$out" "bind-mount"
contains "$out" "external/images"
! mock_has_mutations || fail "mount-derived check executed a mutating command"

pass "check accepts mount mode"
reset_mock_log
out=$(run_cfg "mount check" "$TMP/migration-mount.env" check)
contains "$out" "image mode: mount"
contains "$out" "bind-mount $TMP/external/images"
! mock_has_mutations || fail "mount check executed a mutating command"

pass "check uses the container UID for community-data"
mkdir -p "$TMP/old-uid"
cp -a "$TMP/old/." "$TMP/old-uid/"
chmod 700 "$TMP/old-uid/images/community-data"
sed 's/^UID=.*/UID=9999/; s/^GID=.*/GID=9999/' "$TMP/old/.env" > "$TMP/old-uid/.env"
sed -e "s#^OLD_SPECIES_DIR=.*#OLD_SPECIES_DIR=$TMP/old-uid#" \
    -e 's/^IMAGE_MODE=.*/IMAGE_MODE=auto/' "$TMP/migration.env" > "$TMP/uid-check.env"
if out=$(bash "$SCRIPT" --config "$TMP/uid-check.env" check 2>&1); then
  fail "check accepted community-data not writable by the container UID"
fi
contains "$out" "not writable by 9999:9999"

pass "mount mode preserves symlinks and writes compose.media.yml"
reset_mock_log
rm -f "$TMP/new-mount/Tcas/.env"
out=$(run_cfg "mount prepare" "$TMP/migration-mount.env" --yes prepare)
mount_env="$TMP/new-mount/Tcas/.env"
[[ -f "$mount_env" ]] || fail "mount prepare did not write .env"
contains "$(cat "$mount_env")" "COMPOSE_FILE=compose.yml:compose.tcas.yml:compose.media.yml"
out=$(run_cfg "mount transfer" "$TMP/migration-mount.env" --yes transfer)
[[ -L "$TMP/new-mount/Tcas/images/1" ]] || fail "mount mode did not preserve images/1 symlink"
[[ "$(readlink "$TMP/new-mount/Tcas/images/1")" == "$TMP/external/images/1" ]] || fail "mount mode changed images/1 target"
[[ -f "$TMP/new-mount/Tcas/compose.media.yml" ]] || fail "mount mode did not write compose.media.yml"
contains "$(cat "$TMP/new-mount/Tcas/compose.media.yml")" "$TMP/external/images:$TMP/external/images:ro"

# ---------------------------------------------------------------- whole-directory symlink
mkdir -p "$TMP/external/whole-images/community-data" \
         "$TMP/old-whole" \
         "$TMP/new-whole/Tcas/.git" \
         "$TMP/new-whole/infra/.git" \
         "$TMP/new-whole/infra/scripts" \
         "$TMP/new-whole/backup"
chmod 777 "$TMP/external/whole-images/community-data"

cp -a "$TMP/old/data" "$TMP/old-whole/data"
cp -a "$TMP/old/oba" "$TMP/old-whole/oba"
cp -a "$TMP/old/es_bk" "$TMP/old-whole/es_bk"
cp "$TMP/old/.env" "$TMP/old-whole/.env"
cp "$TMP/old/compose.yml" "$TMP/old-whole/compose.yml"
cp "$TMP/old/compose.tcas.yml" "$TMP/old-whole/compose.tcas.yml"
ln -s "$TMP/external/whole-images" "$TMP/old-whole/images"

cp "$TMP/new/infra/.env" "$TMP/new-whole/infra/.env"
cp "$TMP/new/infra/scripts/allow-origin.sh" "$TMP/new-whole/infra/scripts/allow-origin.sh"
chmod +x "$TMP/new-whole/infra/scripts/allow-origin.sh"
cp "$TMP/new/Tcas/compose.yml" "$TMP/new-whole/Tcas/compose.yml"
cp "$TMP/new/Tcas/compose.tcas.yml" "$TMP/new-whole/Tcas/compose.tcas.yml"

sed \
  -e "s#^OLD_SPECIES_DIR=.*#OLD_SPECIES_DIR=$TMP/old-whole#" \
  -e "s#^NEW_WORKSPACE=.*#NEW_WORKSPACE=$TMP/new-whole#" \
  -e "s#^BACKUP_DIR=.*#BACKUP_DIR=$TMP/new-whole/backup#" \
  -e "s#^NEW_PROJECT=.*#NEW_PROJECT=tcaswhole#" \
  -e "s#^IMAGE_MODE=.*#IMAGE_MODE=auto#" \
  "$TMP/migration.env" > "$TMP/migration-whole.env"

pass "auto detects a whole-directory image symlink"
reset_mock_log
out=$(run_cfg "whole check" "$TMP/migration-whole.env" check)
contains "$out" "image mode: auto"
contains "$out" "image layout: whole-symlink"
contains "$out" "image action: link"
contains "$out" "reused through a symlink"
! mock_has_mutations || fail "whole check executed a mutating command"

pass "whole image symlink is mirrored without copying"
reset_mock_log
rm -f "$TMP/new-whole/Tcas/.env" "$TMP/new-whole/Tcas/images"
out=$(run_cfg "whole prepare" "$TMP/migration-whole.env" --yes prepare)
whole_env="$TMP/new-whole/Tcas/.env"
[[ -f "$whole_env" ]] || fail "whole prepare did not write .env"
contains "$(cat "$whole_env")" "IMAGE_DIR=./images"
contains "$(cat "$whole_env")" "COMPOSE_FILE=compose.yml:compose.tcas.yml"
out=$(run_cfg "whole transfer" "$TMP/migration-whole.env" --yes transfer)
[[ -L "$TMP/new-whole/Tcas/images" ]] || fail "whole image directory is not a symlink"
[[ "$(readlink -f "$TMP/new-whole/Tcas/images")" == "$(readlink -f "$TMP/external/whole-images")" ]] || fail "whole image symlink target is wrong"
[[ ! -e "$TMP/new-whole/Tcas/compose.media.yml" ]] || fail "whole layout wrote compose.media.yml"

# ---------------------------------------------------------------- direct absolute IMAGE_DIR
mkdir -p "$TMP/old-direct" \
         "$TMP/new-direct/Tcas/.git" \
         "$TMP/new-direct/infra/.git" \
         "$TMP/new-direct/infra/scripts" \
         "$TMP/new-direct/backup"

cp -a "$TMP/old/data" "$TMP/old-direct/data"
cp -a "$TMP/old/oba" "$TMP/old-direct/oba"
cp -a "$TMP/old/es_bk" "$TMP/old-direct/es_bk"
cp "$TMP/old/compose.yml" "$TMP/old-direct/compose.yml"
cp "$TMP/old/compose.tcas.yml" "$TMP/old-direct/compose.tcas.yml"
sed "s#^IMAGE_DIR=.*#IMAGE_DIR=$TMP/external/whole-images#" \
  "$TMP/old/.env" > "$TMP/old-direct/.env"

cp "$TMP/new/infra/.env" "$TMP/new-direct/infra/.env"
cp "$TMP/new/infra/scripts/allow-origin.sh" "$TMP/new-direct/infra/scripts/allow-origin.sh"
chmod +x "$TMP/new-direct/infra/scripts/allow-origin.sh"
cp "$TMP/new/Tcas/compose.yml" "$TMP/new-direct/Tcas/compose.yml"
cp "$TMP/new/Tcas/compose.tcas.yml" "$TMP/new-direct/Tcas/compose.tcas.yml"

sed \
  -e "s#^OLD_SPECIES_DIR=.*#OLD_SPECIES_DIR=$TMP/old-direct#" \
  -e "s#^NEW_WORKSPACE=.*#NEW_WORKSPACE=$TMP/new-direct#" \
  -e "s#^BACKUP_DIR=.*#BACKUP_DIR=$TMP/new-direct/backup#" \
  -e "s#^NEW_PROJECT=.*#NEW_PROJECT=tcasdirect#" \
  -e "s#^IMAGE_MODE=.*#IMAGE_MODE=auto#" \
  "$TMP/migration.env" > "$TMP/migration-direct.env"

pass "auto detects an absolute IMAGE_DIR"
reset_mock_log
out=$(run_cfg "direct check" "$TMP/migration-direct.env" check)
contains "$out" "image mode: auto"
contains "$out" "image layout: direct"
contains "$out" "image action: direct"
contains "$out" "use it directly"
! mock_has_mutations || fail "direct check executed a mutating command"

pass "direct IMAGE_DIR is reused without copying"
reset_mock_log
rm -f "$TMP/new-direct/Tcas/.env"
rm -rf "$TMP/new-direct/Tcas/images"
out=$(run_cfg "direct prepare" "$TMP/migration-direct.env" --yes prepare)
direct_env="$TMP/new-direct/Tcas/.env"
[[ -f "$direct_env" ]] || fail "direct prepare did not write .env"
contains "$(cat "$direct_env")" "IMAGE_DIR=$TMP/external/whole-images"
contains "$(cat "$direct_env")" "COMPOSE_FILE=compose.yml:compose.tcas.yml"
out=$(run_cfg "direct transfer" "$TMP/migration-direct.env" --yes transfer)
[[ ! -e "$TMP/new-direct/Tcas/images" ]] || fail "direct layout created a local images directory"
[[ ! -e "$TMP/new-direct/Tcas/compose.media.yml" ]] || fail "direct layout wrote compose.media.yml"

pass "finish stops the old stack"
reset_mock_log
out=$(run finish --yes finish)
contains "$out" "Old stack stopped"
grep -Fq "compose.tcas.yml stop" "$MOCK_LOG" || fail "finish did not stop the old stack"

pass "rollback without --dry-run issues stop and up"
reset_mock_log
out=$(run rollback --yes rollback)
contains "$out" "Restore the old 443 vhost"
contains "$out" "127.0.0.1:6092"
contains "$out" "stopping the new infra stack"
grep -Fq "compose stop" "$MOCK_LOG" || fail "rollback did not issue stop for the new stack"
grep -Fq "compose -f compose.yml -f compose.tcas.yml up -d --wait" "$MOCK_LOG" \
  || fail "rollback did not issue up for the old stack"

pass "rollback --keep-new leaves the new stacks running"
reset_mock_log
out=$(run "rollback keep-new" --yes --keep-new rollback)
contains "$out" "keeping the new stacks running"
contains "$out" "still running"
! grep -Fq "compose stop" "$MOCK_LOG" || fail "keep-new stopped a stack"
contains "$out" "starting the new infra stack"
grep -Fq "compose -f compose.yml -f compose.tcas.yml up -d --wait" "$MOCK_LOG" \
  || fail "keep-new did not start the old stack"

pass "all tests passed"
