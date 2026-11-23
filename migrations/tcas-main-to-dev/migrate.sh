#!/usr/bin/env bash
#
# Phased migration helper for the Tcas deployment.
# The runbook is README.md in this directory.
#
# This script automates the mechanical steps. It never edits Apache, never
# deletes old volumes, and stops with an error when a human decision is needed.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${MIGRATION_CONFIG:-$SCRIPT_DIR/migration.env}"
DRY_RUN=0
ASSUME_YES=0
FORCE=0
COMMAND=
ES_SNAPSHOT=

usage() {
  cat <<'EOF'
Usage: ./migrate.sh [options] <command>

Commands:
  check          validate config, paths, commands and portal release
  prepare        clone, start infra, create env, initial data copy, start staging
  delta          freeze old, final MySQL/Keycloak/files copy, restart new
  cutover        switch the new env to the final URL and print Apache config
  verify         check the final URL, Directus and Keycloak through Apache
  rollback       stop the new stack, start the old one and print the old proxy
  cleanup        print destructive cleanup commands; does not run any command

Options:
  --config FILE  use FILE instead of migration.env
  --dry-run      print commands without execution
  --yes, -y      do not ask for confirmations
  --force        overwrite the new .env if it already exists
  -h, --help     show this help
EOF
}

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

run() {
  if (( DRY_RUN )); then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

run_in() {
  local dir=$1
  shift
  if (( DRY_RUN )); then
    printf '+ cd %q &&' "$dir"
    printf ' %q' "$@"
    printf '\n'
  else
    ( cd "$dir" && "$@" )
  fi
}

confirm() {
  if (( DRY_RUN )); then
    log "would ask: $1"
    return 0
  fi
  (( ASSUME_YES )) && return 0
  local answer
  read -r -p "$1 [y/N] " answer
  [[ "$answer" == y || "$answer" == Y || "$answer" == yes ]]
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

env_get() {
  local file=$1 key=$2 line value
  [[ -f "$file" ]] || return 1
  line=$(grep -E "^${key}=" "$file" | tail -n1 || true)
  [[ -n "$line" ]] || return 1
  value=${line#*=}
  value=${value%$'\r'}
  value=${value#\"}; value=${value%\"}
  value=${value#\'}; value=${value%\'}
  printf '%s' "$value"
}

set_env() {
  local file=$1 key=$2 value=$3
  if (( DRY_RUN )); then
    log "would set $key in $file"
    return
  fi
  python3 - "$file" "$key" "$value" <<'PY'
import os
import sys
import tempfile

path, key, value = sys.argv[1:4]
lines = []
if os.path.exists(path):
    with open(path, encoding="utf-8") as handle:
        lines = handle.readlines()

out = []
done = False
for line in lines:
    if line.startswith(key + "="):
        if not done:
            out.append(f"{key}={value}\n")
            done = True
        continue
    out.append(line)
if not done:
    out.append(f"{key}={value}\n")

directory = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(dir=directory, prefix=".env-")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.writelines(out)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
except Exception:
    os.unlink(tmp)
    raise
PY
}

old_compose() {
  local args=(-f compose.yml)
  if [[ -f "$OLD_SPECIES_DIR/compose.tcas.yml" ]]; then
    args+=(-f compose.tcas.yml)
  fi
  ( cd "$OLD_SPECIES_DIR" && docker compose "${args[@]}" "$@" )
}

new_compose() {
  ( cd "$NEW_SPECIES_DIR" && docker compose "$@" )
}

infra_compose() {
  ( cd "$INFRA_DIR" && docker compose "$@" )
}

old_compose_run() {
  local args=(-f compose.yml)
  if [[ -f "$OLD_SPECIES_DIR/compose.tcas.yml" ]]; then
    args+=(-f compose.tcas.yml)
  fi
  run_in "$OLD_SPECIES_DIR" docker compose "${args[@]}" "$@"
}

new_compose_run() {
  run_in "$NEW_SPECIES_DIR" docker compose "$@"
}

infra_compose_run() {
  run_in "$INFRA_DIR" docker compose "$@"
}

load_context() {
  [[ -f "$CONFIG" ]] || die "config not found: $CONFIG (copy migration.env.example)"
  # shellcheck disable=SC1090
  source "$CONFIG"

  : "${OLD_SPECIES_DIR:?OLD_SPECIES_DIR is required}"
  : "${NEW_WORKSPACE:?NEW_WORKSPACE is required}"
  : "${TCAS_URL:?TCAS_URL is required}"
  : "${STAGING_URL:?STAGING_URL is required}"
  : "${PORTAL_URL:?PORTAL_URL is required}"

  OLD_ENV="$OLD_SPECIES_DIR/.env"
  [[ -f "$OLD_ENV" ]] || die "old .env not found: $OLD_ENV"

  SPECIES_CODE="${SPECIES_CODE:-Tcas}"
  NEW_PROJECT="${NEW_PROJECT:-tcas}"
  NEW_HTTP_PORT="${NEW_HTTP_PORT:-9092}"
  NEW_ES_PORT="${NEW_ES_PORT:-9204}"
  REALM="${REALM:-ibb}"
  CLIENT_ID="${CLIENT_ID:-ibb-client}"
  ES_MODE="${ES_MODE:-snapshot}"
  DEPLOY_REPO="${DEPLOY_REPO:-https://github.com/EMOBase/emobase-deploy.git}"
  INFRA_REPO="${INFRA_REPO:-https://github.com/EMOBase/emobase-infra.git}"
  EMOBASE_WEB_IMAGE="${EMOBASE_WEB_IMAGE:-ghcr.io/emobase/emobase-web:dev}"
  OBA_IMAGE="${OBA_IMAGE:-jboss/base-jdk:7}"

  NEW_SPECIES_DIR="${NEW_SPECIES_DIR:-$NEW_WORKSPACE/$SPECIES_CODE}"
  INFRA_DIR="$NEW_WORKSPACE/infra"
  BACKUP_DIR="${BACKUP_DIR:-$NEW_WORKSPACE/backup}"
  KEYCLOAK_PUBLIC_URL="${KEYCLOAK_PUBLIC_URL:-$TCAS_URL/keycloak}"
  NEW_DIRECTUS_DB="${NEW_DIRECTUS_DB:-directus_${NEW_PROJECT}}"
  NEW_ES_PREFIX="${NEW_ES_PREFIX:-$NEW_PROJECT}"
  OLD_ES_PORT="${OLD_ES_PORT:-9202}"
  OLD_ES_URL="http://127.0.0.1:$OLD_ES_PORT"
  NEW_ES_URL="http://127.0.0.1:$NEW_ES_PORT"

  NEW_INFRA_MYSQL_PASSWORD=""
  OLD_PROJECT=$(env_get "$OLD_ENV" COMPOSE_PROJECT_NAME || true)
  OLD_PROJECT="${OLD_PROJECT:-$(basename "$OLD_SPECIES_DIR" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')}"
  OLD_HTTP_PORT=$(env_get "$OLD_ENV" HTTP_PORT || true)
  OLD_HTTP_PORT="${OLD_HTTP_PORT:-9090}"

  [[ "$NEW_PROJECT" =~ ^[a-z0-9][a-z0-9_-]*$ ]] \
    || die "NEW_PROJECT must be lowercase letters, digits, underscore or hyphen"
  [[ "$NEW_ES_PREFIX" =~ ^[a-z0-9][a-z0-9_-]*$ ]] \
    || die "NEW_ES_PREFIX must be lowercase letters, digits, underscore or hyphen"

  OLD_DIRECTUS_DB="directus"
  OLD_DIRECTUS_VOLUME="${OLD_PROJECT}_directus-data"
  NEW_DIRECTUS_VOLUME="${NEW_PROJECT}_directus-data"

  OLD_MYSQL_PASSWORD=$(env_get "$OLD_ENV" MYSQL_ROOT_PASSWORD || true)
  OLD_DIRECTUS_SECRET=$(env_get "$OLD_ENV" DIRECTUS_SECRET || true)
  OLD_DIRECTUS_ADMIN_EMAIL=$(env_get "$OLD_ENV" DIRECTUS_ADMIN_EMAIL || true)
  OLD_DIRECTUS_ADMIN_PASSWORD=$(env_get "$OLD_ENV" DIRECTUS_ADMIN_PASSWORD || true)
  OLD_CLIENT_SECRET=$(env_get "$OLD_ENV" KEYCLOAK_CLIENT_SECRET || true)
  OLD_SSR_SECRET=$(env_get "$OLD_ENV" SSR_OIDC_SESSION_SECRET || true)
  OLD_COCO_USER=$(env_get "$OLD_ENV" COCO_USERNAME || true)
  OLD_COCO_PASSWORD=$(env_get "$OLD_ENV" COCO_PASSWORD || true)
  OLD_UID=$(env_get "$OLD_ENV" UID || true)
  OLD_GID=$(env_get "$OLD_ENV" GID || true)

  OLD_KEYCLOAK_ADMIN="${OLD_KEYCLOAK_ADMIN:-$(env_get "$OLD_ENV" KEYCLOAK_ADMIN || true)}"
  OLD_KEYCLOAK_ADMIN_PASSWORD="${OLD_KEYCLOAK_ADMIN_PASSWORD:-$(env_get "$OLD_ENV" KEYCLOAK_ADMIN_PASSWORD || true)}"

  OLD_PUBLIC_DATA_DIR=$(env_get "$OLD_ENV" PUBLIC_DATA_DIR || true)
  OLD_PRIVATE_DATA_DIR=$(env_get "$OLD_ENV" PRIVATE_DATA_DIR || true)
  OLD_IMAGE_DIR=$(env_get "$OLD_ENV" IMAGE_DIR || true)
  OLD_PUBLIC_DATA_DIR="${OLD_PUBLIC_DATA_DIR:-./data/public}"
  OLD_PRIVATE_DATA_DIR="${OLD_PRIVATE_DATA_DIR:-./data/private}"
  OLD_IMAGE_DIR="${OLD_IMAGE_DIR:-./images}"
}

require_old_values() {
  local missing=()
  [[ -n "$OLD_MYSQL_PASSWORD" ]] || missing+=("MYSQL_ROOT_PASSWORD")
  [[ -n "$OLD_DIRECTUS_SECRET" ]] || missing+=("DIRECTUS_SECRET")
  [[ -n "$OLD_DIRECTUS_ADMIN_EMAIL" ]] || missing+=("DIRECTUS_ADMIN_EMAIL")
  [[ -n "$OLD_DIRECTUS_ADMIN_PASSWORD" ]] || missing+=("DIRECTUS_ADMIN_PASSWORD")
  [[ -n "$OLD_CLIENT_SECRET" ]] || missing+=("KEYCLOAK_CLIENT_SECRET")
  [[ -n "$OLD_SSR_SECRET" ]] || missing+=("SSR_OIDC_SESSION_SECRET")
  (( ${#missing[@]} == 0 )) || die "old .env is missing: ${missing[*]}"
}

require_admin() {
  [[ -n "$OLD_KEYCLOAK_ADMIN" && -n "$OLD_KEYCLOAK_ADMIN_PASSWORD" ]] || die \
    "Keycloak admin credentials are required. Set OLD_KEYCLOAK_ADMIN and OLD_KEYCLOAK_ADMIN_PASSWORD in migration.env."
}

port_busy() {
  local port=$1
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
  else
    return 1
  fi
}

cmd_check() {
  load_context
  log "checking commands"
  local c
  for c in docker git rsync curl tar python3; do need_cmd "$c"; done
  docker compose version >/dev/null

  log "checking paths"
  [[ -d "$OLD_SPECIES_DIR" ]] || die "old checkout not found: $OLD_SPECIES_DIR"
  [[ "$OLD_PROJECT" != "$NEW_PROJECT" ]] || die "old and new project names are both '$OLD_PROJECT'"
  case "$NEW_WORKSPACE" in
    "$OLD_SPECIES_DIR"|"$OLD_SPECIES_DIR"/*) die "NEW_WORKSPACE must be outside OLD_SPECIES_DIR" ;;
  esac
  require_old_values

  log "checking old paths"
  local path_var path resolved
  for path_var in OLD_PUBLIC_DATA_DIR OLD_PRIVATE_DATA_DIR OLD_IMAGE_DIR; do
    path=${!path_var}
    [[ -n "$path" ]] || continue
    if [[ "$path" == /* ]]; then
      resolved="$path"
    else
      resolved="$OLD_SPECIES_DIR/$path"
    fi
    [[ -e "$resolved" ]] || die "old path not found: $path_var=$path"
    [[ -r "$resolved" ]] || die "old path not readable: $path_var=$path"
  done
  case "$OLD_PUBLIC_DATA_DIR" in
    /*) warn "PUBLIC_DATA_DIR is external; it will be reused read-only, not copied: $OLD_PUBLIC_DATA_DIR" ;;
  esac
  case "$ES_MODE" in
    snapshot|rebuild) ;;
    *) die "ES_MODE must be snapshot or rebuild" ;;
  esac

  [[ -n "$OLD_KEYCLOAK_ADMIN" && -n "$OLD_KEYCLOAK_ADMIN_PASSWORD" ]] || warn \
    "no Keycloak admin credentials; prepare will stop before adding origins"

  log "checking new ports"
  local p
  for p in "$NEW_HTTP_PORT" "$NEW_ES_PORT"; do
    if port_busy "$p"; then die "port $p is already in use"; fi
  done
  if port_busy 8181; then
    warn "port 8181 is in use; check that the old Keycloak does not publish it"
  fi
  if ! port_busy "$OLD_HTTP_PORT"; then
    warn "old site port $OLD_HTTP_PORT is not listening; check HTTP_PORT in $OLD_ENV"
  fi

  if [[ "${SKIP_PORTAL_CHECK:-0}" != "1" ]]; then
    log "checking portal release"
    curl -fsS "$PORTAL_URL/api/genomicsservice/v1/public/versions?status=READY" >/dev/null \
      || die "portal did not return READY versions; publish the Tcas release first"
  fi

  log "checking old volumes and services"
  docker volume inspect "$OLD_DIRECTUS_VOLUME" >/dev/null 2>&1 \
    || die "volume not found: $OLD_DIRECTUS_VOLUME"
  local svc
  for svc in mysql keycloak es; do
    old_compose ps --status running --services 2>/dev/null | grep -qx "$svc" \
      || die "old service is not running: $svc"
  done

  if [[ "$ES_MODE" == "snapshot" ]]; then
    log "checking old Elasticsearch and snapshot directory"
    curl -fsS "$OLD_ES_URL/" >/dev/null 2>&1 \
      || warn "old Elasticsearch is not reachable at $OLD_ES_URL; the snapshot step will fail"
    [[ -d "$OLD_SPECIES_DIR/es_bk" ]] \
      || warn "old es_bk not found: $OLD_SPECIES_DIR/es_bk"
  fi

  log "check complete"
  printf 'old project: %s\nold HTTP port: %s\nold public data: %s (reused, not copied)\nnew project: %s\nstaging: %s\nfinal: %s\n' \
    "$OLD_PROJECT" "$OLD_HTTP_PORT" "$OLD_PUBLIC_DATA_DIR" "$NEW_PROJECT" "$STAGING_URL" "$TCAS_URL"
}

clone_repos() {
  run mkdir -p "$NEW_WORKSPACE"
  if [[ -d "$NEW_SPECIES_DIR/.git" ]]; then
    log "using existing species checkout: $NEW_SPECIES_DIR"
    local branch
    branch=$(git -C "$NEW_SPECIES_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    [[ "$branch" == "dev" ]] || warn "species checkout is on '$branch', expected 'dev'"
  elif [[ -e "$NEW_SPECIES_DIR" ]]; then
    die "$NEW_SPECIES_DIR exists but is not a git checkout"
  else
    run git clone --branch dev "$DEPLOY_REPO" "$NEW_SPECIES_DIR"
  fi

  if [[ -d "$INFRA_DIR/.git" ]]; then
    log "using existing infra checkout: $INFRA_DIR"
  elif [[ -e "$INFRA_DIR" ]]; then
    die "$INFRA_DIR exists but is not a git checkout"
  else
    run git clone "$INFRA_REPO" "$INFRA_DIR"
  fi
}

init_infra() {
  if (( DRY_RUN )); then
    log "would clone/init/start infra with ELASTICSEARCH_HOST_PORT=$NEW_ES_PORT"
    NEW_INFRA_MYSQL_PASSWORD="dry-run"
    return
  fi
  if [[ ! -f "$INFRA_DIR/.env" ]]; then
    run "$INFRA_DIR/init.sh" -y \
      --keycloak-public-url "$KEYCLOAK_PUBLIC_URL" \
      --elasticsearch-host-port "$NEW_ES_PORT"
  else
    log "using existing infra .env"
    set_env "$INFRA_DIR/.env" ELASTICSEARCH_HOST_PORT "$NEW_ES_PORT"
    set_env "$INFRA_DIR/.env" KEYCLOAK_PUBLIC_URL "$KEYCLOAK_PUBLIC_URL"
  fi
  run_in "$INFRA_DIR" docker compose up -d --wait

  NEW_INFRA_MYSQL_PASSWORD=$(env_get "$INFRA_DIR/.env" MYSQL_ROOT_PASSWORD || true)
  [[ -n "$NEW_INFRA_MYSQL_PASSWORD" ]] || die "infra .env has no MYSQL_ROOT_PASSWORD"
}

write_new_env() {
  local env_file="$NEW_SPECIES_DIR/.env"
  if [[ -f "$env_file" && $FORCE -eq 0 ]]; then
    log "using existing new .env: $env_file"
    return
  fi
  if [[ -f "$env_file" ]]; then
    run cp "$env_file" "$env_file.bak"
  fi

  local overlay="compose.$(printf '%s' "$SPECIES_CODE" | tr '[:upper:]' '[:lower:]').yml"
  local compose_file="compose.yml"
  if [[ -f "$NEW_SPECIES_DIR/$overlay" ]]; then
    compose_file="compose.yml:$overlay"
  fi
  local public_data="${OLD_PUBLIC_DATA_DIR:-./data/public}"
  local private_data="${OLD_PRIVATE_DATA_DIR:-./data/private}"
  local image_dir="${OLD_IMAGE_DIR:-./images}"
  local uid="${OLD_UID:-1001}"
  local gid="${OLD_GID:-1001}"

  if (( DRY_RUN )); then
    log "would write $env_file"
    return
  fi

  umask 077
  cat > "$env_file" <<EOF
MAIN_SPECIES=$SPECIES_CODE
EMOBASE_WEB_IMAGE=$EMOBASE_WEB_IMAGE

COMPOSE_PROJECT_NAME=$NEW_PROJECT
PUBLIC_SERVER=$STAGING_URL
HTTP_PORT=$NEW_HTTP_PORT
PUBLIC_DATA_DIR=$public_data
PRIVATE_DATA_DIR=$private_data
IMAGE_DIR=$image_dir
UID=$uid
GID=$gid

PORTAL_SERVER=$PORTAL_URL
PORTAL_INTERNAL_URL=
INTERNAL_API_GENOMICS_SERVICE=$PORTAL_URL/api/genomicsservice/v1

EMOBASE_INFRA_NETWORK=emobase-infra
MYSQL_ROOT_PASSWORD=$NEW_INFRA_MYSQL_PASSWORD
DIRECTUS_DB_HOST=mysql
DIRECTUS_DB_PORT=3306
DIRECTUS_DB_USER=root
DIRECTUS_DB_DATABASE=$NEW_DIRECTUS_DB
EMOBASE_ES_INDEX_PREFIX=$NEW_ES_PREFIX

KEYCLOAK_PUBLIC_URL=$KEYCLOAK_PUBLIC_URL
KEYCLOAK_INTERNAL_URL=http://keycloak:8080/keycloak
KEYCLOAK_REALM=$REALM
KEYCLOAK_REALM_MODE=dedicated
KEYCLOAK_CLIENT_ID=$CLIENT_ID
KEYCLOAK_CLIENT_SECRET=$OLD_CLIENT_SECRET
DIRECTUS_KEYCLOAK_ISSUER_URL=http://keycloak:8080/keycloak/realms/$REALM

DIRECTUS_SECRET=$OLD_DIRECTUS_SECRET
DIRECTUS_ADMIN_EMAIL=$OLD_DIRECTUS_ADMIN_EMAIL
DIRECTUS_ADMIN_PASSWORD=$OLD_DIRECTUS_ADMIN_PASSWORD
SSR_OIDC_SESSION_SECRET=$OLD_SSR_SECRET
COCO_USERNAME=$OLD_COCO_USER
COCO_PASSWORD=$OLD_COCO_PASSWORD

COMPOSE_FILE=$compose_file
EOF
  if [[ -n "${OBA_IMAGE:-}" ]]; then
    printf 'OBA_IMAGE=%s\n' "$OBA_IMAGE" >> "$env_file"
  fi
  chmod 600 "$env_file"
  log "wrote $env_file"
}

copy_files() {
  local rsync_args=(-a)
  [[ "${1:-}" == "delete" ]] && rsync_args+=(--delete)
  local dir
  for dir in data images oba; do
    [[ -d "$OLD_SPECIES_DIR/$dir" ]] || continue
    case "$OLD_SPECIES_DIR/$dir" in
      "$OLD_SPECIES_DIR"/*) ;;
      *) die "refusing to copy outside the old checkout: $OLD_SPECIES_DIR/$dir" ;;
    esac
    run mkdir -p "$NEW_SPECIES_DIR/$dir"
    # -a preserves symlinks. Do not add -L: images/ may contain links into an
    # external read-only mount that must not be dereferenced or copied.
    run rsync "${rsync_args[@]}" "$OLD_SPECIES_DIR/$dir/" "$NEW_SPECIES_DIR/$dir/"
  done
}

delete_new_es_indices() {
  (( DRY_RUN )) && { log "would delete ${NEW_ES_PREFIX}-* indices from port $NEW_ES_PORT"; return; }
  local names idx
  names=$(curl -fsS "http://127.0.0.1:$NEW_ES_PORT/_cat/indices?h=index" 2>/dev/null || true)
  [[ -n "$names" ]] || return 0
  while IFS= read -r idx; do
    [[ "$idx" == "${NEW_ES_PREFIX}-"* ]] || continue
    curl -fsS -X DELETE "http://127.0.0.1:$NEW_ES_PORT/$idx" >/dev/null \
      || warn "could not delete index $idx"
  done <<< "$names"
}

take_es_snapshot() {
  ES_SNAPSHOT="migration-$(date +%Y%m%d%H%M%S)"
  log "taking Elasticsearch snapshot $ES_SNAPSHOT on the old cluster"
  run curl -fsS -X PUT "$OLD_ES_URL/_snapshot/ibb" \
    -H 'Content-Type: application/json' \
    -d '{"type":"fs","settings":{"location":"/es-bk","compress":true}}'
  run curl -fsS -X PUT "$OLD_ES_URL/_snapshot/ibb/$ES_SNAPSHOT?wait_for_completion=true" \
    -H 'Content-Type: application/json' \
    -d '{"indices":"*","include_global_state":true}'
}

copy_es_backup() {
  [[ -d "$OLD_SPECIES_DIR/es_bk" ]] || die "old es_bk not found: $OLD_SPECIES_DIR/es_bk"
  run mkdir -p "$INFRA_DIR/es_bk"
  run rsync -a "$OLD_SPECIES_DIR/es_bk/" "$INFRA_DIR/es_bk/"
}

restore_es_snapshot() {
  [[ -n "$ES_SNAPSHOT" ]] || die "no Elasticsearch snapshot name is set"
  log "registering the snapshot repository on the new Elasticsearch"
  run curl -fsS -X PUT "$NEW_ES_URL/_snapshot/ibb" \
    -H 'Content-Type: application/json' \
    -d '{"type":"fs","settings":{"location":"/es-bk","compress":true}}'
  log "restoring $ES_SNAPSHOT as ${NEW_ES_PREFIX}-*"
  local body
  body=$(printf '%s' \
    '{"indices":"imageservice-*,phenotypeservice-*,ontologyservice-*,goannotationservice-*,publicationservice-*","ignore_unavailable":true,"include_global_state":false,"include_aliases":false,"rename_pattern":"(.+)","rename_replacement":"'"$NEW_ES_PREFIX"'-$1"}')
  run curl -fsS -X POST \
    "$NEW_ES_URL/_snapshot/ibb/$ES_SNAPSHOT/_restore?wait_for_completion=true" \
    -H 'Content-Type: application/json' -d "$body"
  run curl -fsS "$NEW_ES_URL/_cat/indices?h=index,docs.count,store.size&s=index"
}

mirror_volume() {
  docker volume inspect "$OLD_DIRECTUS_VOLUME" >/dev/null 2>&1 \
    || die "volume not found: $OLD_DIRECTUS_VOLUME"
  run docker volume create "$NEW_DIRECTUS_VOLUME" >/dev/null
  run docker run --rm \
    -v "$OLD_DIRECTUS_VOLUME:/from:ro" \
    -v "$NEW_DIRECTUS_VOLUME:/to" \
    alpine sh -c 'rm -rf /to/* /to/.[!.]* /to/..?* 2>/dev/null || true; cp -a /from/. /to/'
}

old_mysql_dump() {
  local db=$1 out=$2
  if (( DRY_RUN )); then
    log "would dump old MySQL database $db to $out"
    return
  fi
  run mkdir -p "$(dirname "$out")"
  old_compose exec -T mysql sh -c \
    "exec mysqldump -uroot -p\"\$MYSQL_ROOT_PASSWORD\" --single-transaction $db" > "$out"
}

infra_mysql_exec() {
  local sql=$1
  if (( DRY_RUN )); then
    log "would run SQL: $sql"
    return
  fi
  infra_compose exec -T mysql sh -c \
    "exec mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -e \"$sql\""
}

infra_mysql_import() {
  local db=$1 file=$2
  if (( DRY_RUN )); then
    log "would import $file into $db"
    return
  fi
  infra_compose exec -T mysql sh -c \
    "exec mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" $db" < "$file"
}

import_directus() {
  local dump=$1
  old_mysql_dump "$OLD_DIRECTUS_DB" "$dump"
  infra_mysql_exec "DROP DATABASE IF EXISTS $NEW_DIRECTUS_DB; CREATE DATABASE $NEW_DIRECTUS_DB;"
  infra_mysql_import "$NEW_DIRECTUS_DB" "$dump"
}

copy_keycloak_db() {
  local label=$1
  require_admin
  [[ "$NEW_INFRA_MYSQL_PASSWORD" != "" ]] || die "infra MySQL password is missing"
  if [[ "$label" == "initial" ]]; then
    confirm "Replace the infra Keycloak database with the old one? Infra must not host other realms." \
      || die "aborted before replacing the infra Keycloak database"
  fi
  local dump="$BACKUP_DIR/keycloak-$label.sql"
  old_mysql_dump "keycloak" "$dump"

  run_in "$INFRA_DIR" docker compose stop keycloak
  infra_mysql_exec "DROP DATABASE IF EXISTS keycloak; CREATE DATABASE keycloak;"
  infra_mysql_import "keycloak" "$dump"
  set_env "$INFRA_DIR/.env" KEYCLOAK_ADMIN "$OLD_KEYCLOAK_ADMIN"
  set_env "$INFRA_DIR/.env" KEYCLOAK_ADMIN_PASSWORD "$OLD_KEYCLOAK_ADMIN_PASSWORD"
  run_in "$INFRA_DIR" docker compose up -d --wait keycloak
  add_origins
}

add_origins() {
  require_admin
  run_in "$INFRA_DIR" ./scripts/allow-origin.sh \
    --realm "$REALM" --client-id "$CLIENT_ID" \
    "$TCAS_URL" "$STAGING_URL"
}

setup_directus() {
  run_in "$NEW_SPECIES_DIR" docker compose run --rm setup-directus
}

start_new() {
  run_in "$NEW_SPECIES_DIR" docker compose up -d --wait
}

verify_staging() {
  local strict=${1:-0}
  (( DRY_RUN )) && { log "would check staging"; return; }
  local fail=warn
  (( strict )) && fail=die
  log "staging checks"
  curl -k -fsSI "$STAGING_URL" >/dev/null || "$fail" "could not reach $STAGING_URL"
  curl -k -fsSI "$STAGING_URL/ibb/directus" >/dev/null || "$fail" "could not reach $STAGING_URL/ibb/directus"
  cat <<EOF

Staging is at:   $STAGING_URL
Final URL:       $TCAS_URL
Keycloak admin:  $KEYCLOAK_PUBLIC_URL/admin/

Test one real user login on the staging URL before continuing.
EOF
}

cmd_prepare() {
  load_context
  cmd_check
  require_admin
  case "$ES_MODE" in
    snapshot|rebuild) ;;
    *) die "ES_MODE must be snapshot or rebuild" ;;
  esac
  run mkdir -p "$BACKUP_DIR"
  clone_repos
  init_infra
  write_new_env
  copy_files
  mirror_volume
  import_directus "$BACKUP_DIR/directus-initial.sql"
  copy_keycloak_db initial
  setup_directus
  start_new
  verify_staging
}

cmd_delta() {
  load_context
  require_admin
  case "$ES_MODE" in
    snapshot|rebuild) ;;
    *) die "ES_MODE must be snapshot or rebuild" ;;
  esac
  [[ -f "$NEW_SPECIES_DIR/.env" ]] || die "prepare has not run: $NEW_SPECIES_DIR/.env is missing"
  [[ -n "$NEW_INFRA_MYSQL_PASSWORD" ]] || NEW_INFRA_MYSQL_PASSWORD=$(env_get "$INFRA_DIR/.env" MYSQL_ROOT_PASSWORD || true)
  [[ -n "$NEW_INFRA_MYSQL_PASSWORD" ]] || die "infra .env has no MYSQL_ROOT_PASSWORD"

  log "freezing the old application (databases stay up for the copy)"
  old_compose_run stop
  old_compose_run up -d --wait mysql keycloak es
  new_compose_run stop

  import_directus "$BACKUP_DIR/directus-final.sql"

  log "final Keycloak copy"
  old_compose_run stop keycloak
  copy_keycloak_db final

  log "final files and uploads"
  copy_files delete
  mirror_volume

  setup_directus
  if [[ "$ES_MODE" == "snapshot" ]]; then
    take_es_snapshot
    copy_es_backup
    delete_new_es_indices
    restore_es_snapshot
  else
    delete_new_es_indices
  fi
  start_new
  verify_staging 1

  log "stopping the old stack; volumes are kept for rollback"
  old_compose_run stop
}

cmd_cutover() {
  load_context
  require_admin
  [[ -f "$NEW_SPECIES_DIR/.env" ]] || die "prepare has not run"
  set_env "$NEW_SPECIES_DIR/.env" PUBLIC_SERVER "$TCAS_URL"
  run_in "$NEW_SPECIES_DIR" docker compose up -d --wait
  add_origins
  cat <<EOF

Final Apache configuration (apply manually, then remove the 9443 vhost):

  ProxyPreserveHost On
  RequestHeader set X-Forwarded-Proto "https"
  ProxyPass        /keycloak  http://127.0.0.1:8181/keycloak
  ProxyPassReverse /keycloak  http://127.0.0.1:8181/keycloak
  ProxyPass        /          http://127.0.0.1:$NEW_HTTP_PORT/
  ProxyPassReverse /          http://127.0.0.1:$NEW_HTTP_PORT/

Apply apache-final.conf.example to the 443 vhost now. Until `/` points to
$NEW_HTTP_PORT, <TCAS_URL> still reaches the old stack.

Then run: ./migrate.sh verify
EOF
}

cmd_verify() {
  load_context
  log "final checks"
  if old_compose ps --status running --services 2>/dev/null | grep -qx nginx; then
    die "the old nginx is still running; stop the old stack before verifying the final URL"
  fi
  if ! new_compose ps --status running --services 2>/dev/null | grep -qx nginx; then
    die "the new species stack is not running"
  fi
  curl -fsSI "$TCAS_URL" >/dev/null \
    || die "$TCAS_URL is not reachable; is the 443 vhost pointing at $NEW_HTTP_PORT?"
  curl -fsSI "$TCAS_URL/ibb/directus" >/dev/null \
    || warn "Directus is not reachable at $TCAS_URL/ibb/directus"
  curl -fsSI "$TCAS_URL/keycloak/realms/$REALM" >/dev/null \
    || warn "Keycloak realm $REALM is not reachable at $TCAS_URL/keycloak"

  cat <<EOF

Final site:     $TCAS_URL
Directus:       $TCAS_URL/ibb/directus
Keycloak:       $TCAS_URL/keycloak/admin/

Open the site and test one real user login.
EOF
}

cmd_rollback() {
  load_context
  log "stopping the new stack"
  new_compose_run stop
  log "starting the old stack"
  old_compose_run up -d --wait
  cat <<EOF

The new species stack is stopped. The new infra stack, if running, was not
stopped; it does not serve the public site and can stay up for diagnosis or a
retry.

Restore the old Apache configuration:
  443 / -> 127.0.0.1:$OLD_HTTP_PORT, and /ibb/keycloak through the old stack.

Remove or disable the temporary 9443 vhost, then reload Apache:

  apachectl configtest
  systemctl reload apache2

Verify the old site and login. Do not run cleanup: the old volumes are the
rollback window and still hold the authoritative data.

Old project: $OLD_PROJECT
EOF
}

cmd_cleanup() {
  load_context
  cat <<EOF
After the retention period, review and run these on the server:

  cd "$OLD_SPECIES_DIR" && docker compose -f compose.yml -f compose.tcas.yml down
  docker volume rm ${OLD_PROJECT}_mysql-data ${OLD_PROJECT}_es-data \\
    ${OLD_PROJECT}_blast-data ${OLD_PROJECT}_jbrowse2-data \\
    ${OLD_DIRECTUS_VOLUME}
  # keep ${NEW_DIRECTUS_VOLUME}, which the new stack uses
  # keep ${BACKUP_DIR} until the retention period ends

Then delete this migration folder.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG=$2; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) COMMAND=$1; shift ;;
  esac
done

[[ -n "$COMMAND" ]] || { usage; exit 1; }

case "$COMMAND" in
  check) cmd_check ;;
  prepare) cmd_prepare ;;
  delta) cmd_delta ;;
  cutover) cmd_cutover ;;
  verify) cmd_verify ;;
  rollback) cmd_rollback ;;
  cleanup) cmd_cleanup ;;
  *) die "unknown command: $COMMAND (run --help)" ;;
esac
