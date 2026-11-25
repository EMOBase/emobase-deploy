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
KEEP_NEW=0
COMMAND=
ES_SNAPSHOT=

usage() {
  cat <<'EOF'
Usage: ./migrate.sh [options] <command>

Commands:
  init            ask for paths and URLs and write migration.env
  apache          generate the final Apache vhost
  check           validate config, paths, commands and portal release
  prepare         clone, start infra, write config (no data copy)
  transfer        copy all data while the old site stays live
  verify          check the final URL, Directus and Keycloak through Apache
  finish          stop the old stack after verification
  rollback        stop the new stack, start the old one and print the old proxy
  cleanup         print destructive cleanup commands; does not run any command

Options:
  --config FILE  use FILE instead of migration.env
  --dry-run      print commands without execution
  --yes, -y      do not ask for confirmations
  --force        overwrite migration.env or the new .env if it already exists
  --keep-new     rollback: leave the new stack running on 9092
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

ask() {
  local var="$1" label="$2" default="$3" validator="${4:-}" error="${5:-Invalid value}" value
  if [[ -n "${!var:-}" ]]; then
    if [[ -n "$validator" ]] && ! "$validator" "${!var}"; then
      die "$error: ${!var}"
    fi
    return 0
  fi
  if (( ASSUME_YES )); then
    printf -v "$var" '%s' "$default"
    if [[ -n "$validator" ]] && ! "$validator" "$default"; then
      die "$error: $default"
    fi
    return 0
  fi
  [[ -t 0 ]] || die "cannot ask for $label: stdin is not a terminal (use --yes or set $var)"
  while true; do
    if [[ -n "$default" ]]; then
      read -r -e -p "$label [$default]: " value
    else
      read -r -e -p "$label: " value
    fi
    value="${value:-$default}"
    if [[ -z "$validator" ]] || "$validator" "$value"; then
      printf -v "$var" '%s' "$value"
      return 0
    fi
    printf 'ERROR: %s\n' "$error" >&2
  done
}

resolve_path() {
  python3 - "$1" <<'PY'
import os
import sys

print(os.path.abspath(os.path.expanduser(sys.argv[1])))
PY
}

valid_url() {
  [[ "$1" =~ ^https?://[^/]+ ]]
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

valid_project() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9_-]*$ ]]
}

valid_es_mode() {
  [[ "$1" == snapshot || "$1" == rebuild ]]
}

valid_image_mode() {
  [[ "$1" == auto || "$1" == copy || "$1" == mount ]]
}

valid_nonempty() {
  [[ -n "$1" ]]
}

valid_old_checkout() {
  [[ -d "$1" && -f "$1/.env" ]]
}

valid_new_workspace() {
  [[ "$1" != "$OLD_SPECIES_DIR" && "$1" != "$OLD_SPECIES_DIR"/* ]]
}

ask_path() {
  local var="$1" label="$2" default="$3" validator="${4:-}" error="${5:-Invalid path}" value
  if [[ -n "${!var:-}" ]]; then
    value=$(resolve_path "${!var}")
  elif (( ASSUME_YES )); then
    value=$(resolve_path "$default")
  else
    [[ -t 0 ]] || die "cannot ask for $label: stdin is not a terminal (use --yes or set $var)"
    while true; do
      if [[ -n "$default" ]]; then
        read -r -e -p "$label [$default]: " value
      else
        read -r -e -p "$label: " value
      fi
      value="${value:-$default}"
      [[ -n "$value" ]] || { printf 'ERROR: %s is required\n' "$label" >&2; continue; }
      value=$(resolve_path "$value")
      if [[ -z "$validator" ]] || "$validator" "$value"; then
        printf -v "$var" '%s' "$value"
        return 0
      fi
      printf 'ERROR: %s\n' "$error" >&2
    done
  fi
  [[ -n "$value" ]] || die "$error: $label is required"
  if [[ -n "$validator" ]] && ! "$validator" "$value"; then
    die "$error: $value"
  fi
  printf -v "$var" '%s' "$value"
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
  IMAGE_MODE="${IMAGE_MODE:-auto}"
  IMAGE_MOUNT_SOURCE="${IMAGE_MOUNT_SOURCE:-}"
  case "$IMAGE_MODE" in
    auto|copy|mount) ;;
    *) die "IMAGE_MODE must be auto, copy or mount" ;;
  esac
  DEPLOY_REPO="${DEPLOY_REPO:-https://github.com/EMOBase/emobase-deploy.git}"
  INFRA_REPO="${INFRA_REPO:-https://github.com/EMOBase/emobase-infra.git}"
  EMOBASE_WEB_IMAGE="${EMOBASE_WEB_IMAGE:-ghcr.io/emobase/emobase-web:dev}"
  OBA_IMAGE="${OBA_IMAGE:-jboss/base-jdk:7}"

  NEW_SPECIES_DIR="${NEW_SPECIES_DIR:-$NEW_WORKSPACE/$SPECIES_CODE}"
  INFRA_DIR="$NEW_WORKSPACE/infra"
  BACKUP_DIR="${BACKUP_DIR:-$NEW_WORKSPACE/backup}"
  KEYCLOAK_PUBLIC_URL="${KEYCLOAK_PUBLIC_URL:-$TCAS_URL/keycloak}"
  TCAS_HOST=$(python3 - "$TCAS_URL" <<'PY'
import sys
from urllib.parse import urlsplit

print(urlsplit(sys.argv[1]).hostname or "")
PY
)
  [[ -n "$TCAS_HOST" ]] || die "TCAS_URL has no host: $TCAS_URL"
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

  if [[ "$OLD_IMAGE_DIR" == /* ]]; then
    OLD_IMAGE_PATH="$OLD_IMAGE_DIR"
  else
    OLD_IMAGE_PATH="$OLD_SPECIES_DIR/$OLD_IMAGE_DIR"
  fi

  IMAGE_LAYOUT=""
  IMAGE_ACTION=""
  IMAGE_TARGET=""

  if [[ "$OLD_IMAGE_DIR" == /* ]]; then
    IMAGE_LAYOUT="direct"
  elif [[ -L "$OLD_IMAGE_PATH" ]]; then
    IMAGE_LAYOUT="whole-symlink"
  elif [[ -d "$OLD_IMAGE_PATH" ]]; then
    local mount_target=""
    local image_real=""
    image_real=$(readlink -f "$OLD_IMAGE_PATH" 2>/dev/null || true)
    if command -v findmnt >/dev/null 2>&1; then
      mount_target=$(findmnt -T "$OLD_IMAGE_PATH" -no TARGET 2>/dev/null | head -n1 || true)
    fi
    if [[ -n "$mount_target" && -n "$image_real" && "$(readlink -f "$mount_target" 2>/dev/null || printf '%s' "$mount_target")" == "$image_real" ]]; then
      IMAGE_LAYOUT="whole-mount"
    elif find "$OLD_IMAGE_PATH" -maxdepth 1 -type l -print -quit 2>/dev/null | grep -q .; then
      IMAGE_LAYOUT="symlink-farm"
    else
      IMAGE_LAYOUT="real-files"
    fi
  fi

  NEW_IMAGE_DIR="./images"
  case "$IMAGE_LAYOUT" in
    direct)
      IMAGE_TARGET="$OLD_IMAGE_PATH"
      case "$IMAGE_MODE" in
        auto|mount) IMAGE_ACTION="direct" ;;
        copy) IMAGE_ACTION="copy" ;;
      esac
      ;;
    whole-symlink|whole-mount)
      IMAGE_TARGET=$(readlink -f "$OLD_IMAGE_PATH" 2>/dev/null || printf '%s' "$OLD_IMAGE_PATH")
      case "$IMAGE_MODE" in
        auto|mount) IMAGE_ACTION="link" ;;
        copy) IMAGE_ACTION="copy" ;;
      esac
      ;;
    symlink-farm)
      IMAGE_TARGET="$OLD_IMAGE_PATH"
      case "$IMAGE_MODE" in
        auto|mount) IMAGE_ACTION="mount" ;;
        copy) IMAGE_ACTION="copy" ;;
      esac
      ;;
    real-files)
      IMAGE_TARGET="$OLD_IMAGE_PATH"
      case "$IMAGE_MODE" in
        auto|copy) IMAGE_ACTION="copy" ;;
        mount) IMAGE_ACTION="invalid" ;;
      esac
      ;;
    "") IMAGE_ACTION="invalid" ;;
  esac
  if [[ "$IMAGE_ACTION" == "direct" ]]; then
    NEW_IMAGE_DIR="$IMAGE_TARGET"
  fi

  if [[ "$IMAGE_ACTION" == "mount" && -z "$IMAGE_MOUNT_SOURCE" ]]; then
    local image_link image_target
    image_link=$(find "$OLD_IMAGE_PATH" -maxdepth 1 -type l -print -quit 2>/dev/null || true)
    if [[ -n "$image_link" ]]; then
      image_target=$(readlink -f "$image_link" 2>/dev/null || true)
      [[ -n "$image_target" ]] && IMAGE_MOUNT_SOURCE=$(dirname "$image_target")
    fi
  fi
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

path_writable_by() {
  local path=$1 uid=$2 gid=$3 owner group mode bits info
  [[ -e "$path" ]] || return 1

  if command -v findmnt >/dev/null 2>&1; then
    local opts
    opts=$(findmnt -T "$path" -no OPTIONS 2>/dev/null || true)
    case ",$opts," in
      *",ro,"*) return 1 ;;
    esac
  fi

  if info=$(stat -c '%u %g %a' "$path" 2>/dev/null); then
    read -r owner group mode <<< "$info"
  elif info=$(stat -f '%u %g %Lp' "$path" 2>/dev/null); then
    read -r owner group mode <<< "$info"
  else
    return 1
  fi

  (( uid == 0 )) && return 0
  bits=$((8#$mode))
  if (( uid == owner && (bits & 0200) != 0 )); then
    return 0
  fi
  if (( gid == group && (bits & 0020) != 0 )); then
    return 0
  fi
  (( bits & 0002 ))
}

cmd_init() {
  need_cmd python3
  local example="$SCRIPT_DIR/migration.env.example"
  [[ -f "$example" ]] || die "example config not found: $example"

  if [[ -e "$CONFIG" ]]; then
    if (( FORCE || DRY_RUN )); then
      :
    elif (( ASSUME_YES )); then
      die "$CONFIG already exists; use --force to overwrite"
    elif [[ -t 0 ]] && confirm "Overwrite $CONFIG?"; then
      :
    else
      log "keeping existing config: $CONFIG"
      return 0
    fi
  fi

  local cfg_old cfg_ws cfg_backup cfg_tcas cfg_portal cfg_kc
  local cfg_http cfg_es cfg_project cfg_species cfg_realm cfg_client
  local cfg_es_mode cfg_image_mode cfg_web cfg_oba
  cfg_old=$(env_get "$CONFIG" OLD_SPECIES_DIR || true)
  cfg_ws=$(env_get "$CONFIG" NEW_WORKSPACE || true)
  cfg_backup=$(env_get "$CONFIG" BACKUP_DIR || true)
  cfg_tcas=$(env_get "$CONFIG" TCAS_URL || true)
  cfg_portal=$(env_get "$CONFIG" PORTAL_URL || true)
  cfg_kc=$(env_get "$CONFIG" KEYCLOAK_PUBLIC_URL || true)
  cfg_http=$(env_get "$CONFIG" NEW_HTTP_PORT || true)
  cfg_es=$(env_get "$CONFIG" NEW_ES_PORT || true)
  cfg_project=$(env_get "$CONFIG" NEW_PROJECT || true)
  cfg_species=$(env_get "$CONFIG" SPECIES_CODE || true)
  cfg_realm=$(env_get "$CONFIG" REALM || true)
  cfg_client=$(env_get "$CONFIG" CLIENT_ID || true)
  cfg_es_mode=$(env_get "$CONFIG" ES_MODE || true)
  cfg_image_mode=$(env_get "$CONFIG" IMAGE_MODE || true)
  cfg_web=$(env_get "$CONFIG" EMOBASE_WEB_IMAGE || true)
  cfg_oba=$(env_get "$CONFIG" OBA_IMAGE || true)

  local ws_default=${cfg_ws:-$(resolve_path "$SCRIPT_DIR/../../..")}

  ask_path OLD_SPECIES_DIR "Old Tcas checkout" \
    "$cfg_old" valid_old_checkout "Enter a directory containing .env"
  local old_public old_species old_realm old_client
  old_public=$(env_get "$OLD_SPECIES_DIR/.env" PUBLIC_SERVER || true)
  if [[ -z "$old_public" ]]; then
    old_public=$(env_get "$OLD_SPECIES_DIR/.env" TCAS_URL || true)
  fi
  old_species=$(env_get "$OLD_SPECIES_DIR/.env" MAIN_SPECIES || true)
  old_realm=$(env_get "$OLD_SPECIES_DIR/.env" KEYCLOAK_REALM || true)
  old_client=$(env_get "$OLD_SPECIES_DIR/.env" KEYCLOAK_CLIENT_ID || true)
  ask_path NEW_WORKSPACE "New workspace" \
    "$ws_default" valid_new_workspace "Must be outside the old checkout"
  ask_path BACKUP_DIR "Backup directory" \
    "${cfg_backup:-$NEW_WORKSPACE/backup}"

  ask TCAS_URL "Final Tcas URL" "${cfg_tcas:-$old_public}" valid_url \
    "Enter an http(s) URL"
  ask KEYCLOAK_PUBLIC_URL "Final Keycloak URL" \
    "${cfg_kc:-${TCAS_URL%/}/keycloak}" valid_url "Enter an http(s) URL"
  ask PORTAL_URL "Portal URL" "$cfg_portal" valid_url "Enter an http(s) URL"

  ask NEW_HTTP_PORT "New species HTTP port" "${cfg_http:-9092}" valid_port \
    "Enter a port from 1 to 65535"
  ask NEW_ES_PORT "New infra Elasticsearch port" "${cfg_es:-9204}" valid_port \
    "Enter a port from 1 to 65535"
  ask NEW_PROJECT "New Compose project" "${cfg_project:-tcas}" valid_project \
    "Use lowercase letters, digits, _ or -"
  SPECIES_CODE="${cfg_species:-${old_species:-Tcas}}"
  REALM="${cfg_realm:-${old_realm:-ibb}}"
  CLIENT_ID="${cfg_client:-${old_client:-ibb-client}}"
  ask ES_MODE "Elasticsearch mode (snapshot/rebuild)" \
    "${cfg_es_mode:-snapshot}" valid_es_mode "Use snapshot or rebuild"
  ask IMAGE_MODE "Image mode (auto/copy/mount)" \
    "${cfg_image_mode:-auto}" valid_image_mode "Use auto, copy or mount"
  ask EMOBASE_WEB_IMAGE "New web image" \
    "${cfg_web:-ghcr.io/emobase/emobase-web:dev}" valid_nonempty "Required"
  ask OBA_IMAGE "OBA image" "${cfg_oba:-jboss/base-jdk:7}" valid_nonempty "Required"

  local admin_note=0
  env_get "$OLD_SPECIES_DIR/.env" KEYCLOAK_ADMIN >/dev/null 2>&1 || admin_note=1

  if (( DRY_RUN )); then
    log "would write $CONFIG"
    printf 'OLD_SPECIES_DIR=%s\n' "$OLD_SPECIES_DIR"
    printf 'NEW_WORKSPACE=%s\n' "$NEW_WORKSPACE"
    printf 'BACKUP_DIR=%s\n' "$BACKUP_DIR"
    printf 'TCAS_URL=%s\n' "$TCAS_URL"
    printf 'PORTAL_URL=%s\n' "$PORTAL_URL"
    printf 'KEYCLOAK_PUBLIC_URL=%s\n' "$KEYCLOAK_PUBLIC_URL"
    printf 'NEW_HTTP_PORT=%s\n' "$NEW_HTTP_PORT"
    printf 'NEW_ES_PORT=%s\n' "$NEW_ES_PORT"
    printf 'NEW_PROJECT=%s\n' "$NEW_PROJECT"
    printf 'SPECIES_CODE=%s\n' "$SPECIES_CODE"
    printf 'REALM=%s\n' "$REALM"
    printf 'CLIENT_ID=%s\n' "$CLIENT_ID"
    printf 'ES_MODE=%s\n' "$ES_MODE"
    printf 'IMAGE_MODE=%s\n' "$IMAGE_MODE"
    printf 'EMOBASE_WEB_IMAGE=%s\n' "$EMOBASE_WEB_IMAGE"
    printf 'OBA_IMAGE=%s\n' "$OBA_IMAGE"
    return 0
  fi

  python3 - "$example" "$CONFIG" \
    "OLD_SPECIES_DIR=$OLD_SPECIES_DIR" \
    "NEW_WORKSPACE=$NEW_WORKSPACE" \
    "BACKUP_DIR=$BACKUP_DIR" \
    "TCAS_URL=$TCAS_URL" \
    "PORTAL_URL=$PORTAL_URL" \
    "KEYCLOAK_PUBLIC_URL=$KEYCLOAK_PUBLIC_URL" \
    "NEW_HTTP_PORT=$NEW_HTTP_PORT" \
    "NEW_ES_PORT=$NEW_ES_PORT" \
    "NEW_PROJECT=$NEW_PROJECT" \
    "SPECIES_CODE=$SPECIES_CODE" \
    "REALM=$REALM" \
    "CLIENT_ID=$CLIENT_ID" \
    "ES_MODE=$ES_MODE" \
    "IMAGE_MODE=$IMAGE_MODE" \
    "EMOBASE_WEB_IMAGE=$EMOBASE_WEB_IMAGE" \
    "OBA_IMAGE=$OBA_IMAGE" <<'PY'
import os
import shlex
import sys
import tempfile

example, config = sys.argv[1], sys.argv[2]
pairs = dict(arg.split("=", 1) for arg in sys.argv[3:])

with open(example, encoding="utf-8") as handle:
    lines = handle.readlines()

out = []
seen = set()
for line in lines:
    stripped = line.lstrip()
    if "=" in line and not stripped.startswith("#"):
        key = line.split("=", 1)[0].strip()
        if key in pairs:
            out.append(f"{key}={shlex.quote(pairs[key])}\n")
            seen.add(key)
            continue
    out.append(line)

for key, value in pairs.items():
    if key not in seen:
        out.append(f"{key}={shlex.quote(value)}\n")

directory = os.path.dirname(config) or "."
fd, tmp = tempfile.mkstemp(dir=directory, prefix=".env-")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.writelines(out)
    os.chmod(tmp, 0o600)
    os.replace(tmp, config)
except Exception:
    os.unlink(tmp)
    raise
PY

  log "wrote $CONFIG"
  printf '\nNext:\n  ./migrate.sh check\n'
  if (( admin_note )); then
    printf '\nThe old .env has no KEYCLOAK_ADMIN. Set OLD_KEYCLOAK_ADMIN and\n'
    printf 'OLD_KEYCLOAK_ADMIN_PASSWORD in %s if needed.\n' "$CONFIG"
  fi
}

detect_cert_pair() {
  local cert="${SSL_CERT_FILE:-}" key="${SSL_CERT_KEY_FILE:-}"
  if [[ -z "$cert" && -z "$key" ]]; then
    if [[ -f "/etc/letsencrypt/live/$TCAS_HOST/fullchain.pem" \
       && -f "/etc/letsencrypt/live/$TCAS_HOST/privkey.pem" ]]; then
      cert="/etc/letsencrypt/live/$TCAS_HOST/fullchain.pem"
      key="/etc/letsencrypt/live/$TCAS_HOST/privkey.pem"
    else
      local candidate base nullglob
      nullglob=$(shopt -p nullglob || true)
      shopt -s nullglob
      for candidate in "/etc/ssl/certs/${TCAS_HOST}.pem" \
                       "/etc/ssl/certs/${TCAS_HOST}"+*.pem; do
        base=$(basename "$candidate" .pem)
        if [[ -f "/etc/ssl/private/${base}-key.pem" ]]; then
          cert=$candidate
          key="/etc/ssl/private/${base}-key.pem"
          break
        fi
      done
      eval "$nullglob"
    fi
  fi
  if [[ -z "$cert" || -z "$key" ]]; then
    warn "could not detect a TLS certificate for $TCAS_HOST; using placeholders"
    SSL_CERT_FILE="${cert:-/path/fullchain.pem}"
    SSL_CERT_KEY_FILE="${key:-/path/privkey.pem}"
    return 0
  fi
  if [[ ! -e "$cert" ]]; then
    warn "certificate not found: $cert (edit the generated vhosts)"
  elif [[ ! -f "$cert" ]]; then
    warn "certificate is not a file: $cert (edit the generated vhosts)"
  fi
  if [[ ! -e "$key" ]]; then
    if [[ -n "${SSL_CERT_KEY_FILE:-}" ]]; then
      warn "private key is not visible to this user; using the configured path: $key"
    else
      warn "private key not found: $key (edit the generated vhosts)"
    fi
  elif [[ ! -f "$key" ]]; then
    warn "private key is not a file: $key (edit the generated vhosts)"
  fi
  SSL_CERT_FILE=$cert
  SSL_CERT_KEY_FILE=$key
}

cmd_apache() {
  load_context
  detect_cert_pair
  local final="$NEW_WORKSPACE/apache-final.conf"
  if (( DRY_RUN )); then
    log "would write $final"
    return 0
  fi

  run mkdir -p "$NEW_WORKSPACE"
  cat > "$final" <<EOF
# Generated by ./migrate.sh apache for $TCAS_HOST.
# Final 443 vhost; 443 is already in ports.conf.
<VirtualHost *:443>
    ServerName $TCAS_HOST

    SSLEngine on
    SSLCertificateFile    $SSL_CERT_FILE
    SSLCertificateKeyFile $SSL_CERT_KEY_FILE

    ProxyPreserveHost On
    RequestHeader set X-Forwarded-Proto "https"
    LimitRequestFieldSize 16384

    ProxyPass        /keycloak  http://127.0.0.1:8181/keycloak
    ProxyPassReverse /keycloak  http://127.0.0.1:8181/keycloak

    ProxyPass        /  http://127.0.0.1:$NEW_HTTP_PORT/
    ProxyPassReverse /  http://127.0.0.1:$NEW_HTTP_PORT/
</VirtualHost>
EOF

  chmod 644 "$final"
  log "certificate: $SSL_CERT_FILE"
  log "key:         $SSL_CERT_KEY_FILE"
  log "wrote $final"
  cat <<EOF

Review the final vhost and edit the certificate paths if needed:
  $final

At the switch, replace the 443 vhost with this file.
EOF
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

  log "checking image layout"
  printf 'image mode: %s\nimage layout: %s\nimage action: %s\n' \
    "$IMAGE_MODE" "$IMAGE_LAYOUT" "$IMAGE_ACTION"
  local image_uid="${OLD_UID:-1001}"
  local image_gid="${OLD_GID:-1001}"
  case "$IMAGE_LAYOUT" in
    direct)
      [[ -n "$IMAGE_TARGET" && -d "$IMAGE_TARGET" ]] \
        || die "image target not found or not a directory: $IMAGE_TARGET"
      [[ -r "$IMAGE_TARGET" ]] || die "image target not readable: $IMAGE_TARGET"
      if [[ "$IMAGE_ACTION" == "direct" ]]; then
        warn "IMAGE_DIR is absolute; the new stack will use it directly: $IMAGE_TARGET"
        path_writable_by "$IMAGE_TARGET/community-data" "$image_uid" "$image_gid" \
          || die "community-data is not writable by ${image_uid}:${image_gid} at $IMAGE_TARGET/community-data; imageservice requires a writable community-data. Use IMAGE_MODE=copy or make it writable for that user"
      elif [[ "$IMAGE_ACTION" == "copy" ]]; then
        warn "absolute image directory will be copied into ./images"
      fi
      ;;
    whole-symlink|whole-mount)
      [[ -n "$IMAGE_TARGET" && -d "$IMAGE_TARGET" ]] \
        || die "image target not found or not a directory: $IMAGE_TARGET"
      [[ -r "$IMAGE_TARGET" ]] || die "image target not readable: $IMAGE_TARGET"
      if [[ "$IMAGE_ACTION" == "link" ]]; then
        warn "whole image directory will be reused through a symlink: $OLD_IMAGE_PATH -> $IMAGE_TARGET"
        path_writable_by "$IMAGE_TARGET/community-data" "$image_uid" "$image_gid" \
          || die "community-data is not writable by ${image_uid}:${image_gid} at $IMAGE_TARGET/community-data; imageservice requires a writable community-data. Use IMAGE_MODE=copy or make it writable for that user"
      elif [[ "$IMAGE_ACTION" == "copy" ]]; then
        warn "whole image directory will be copied into ./images"
      fi
      ;;
    symlink-farm)
      if [[ "$IMAGE_ACTION" == "copy" ]]; then
        warn "IMAGE_DIR contains symlinks; copy mode will materialize them into ./images"
      elif [[ "$IMAGE_ACTION" == "mount" ]]; then
        [[ -n "$IMAGE_MOUNT_SOURCE" ]] || die \
          "IMAGE_ACTION=mount requires IMAGE_MOUNT_SOURCE (could not derive it from IMAGE_DIR symlinks)"
        [[ -d "$IMAGE_MOUNT_SOURCE" ]] || die "IMAGE_MOUNT_SOURCE not found: $IMAGE_MOUNT_SOURCE"
        [[ -r "$IMAGE_MOUNT_SOURCE" ]] || die "IMAGE_MOUNT_SOURCE not readable: $IMAGE_MOUNT_SOURCE"
        warn "IMAGE_ACTION=mount will bind-mount $IMAGE_MOUNT_SOURCE read-only inside imageservice and phenotypeservice"
        path_writable_by "$OLD_IMAGE_PATH/community-data" "$image_uid" "$image_gid" \
          || die "community-data is not writable by ${image_uid}:${image_gid} at $OLD_IMAGE_PATH/community-data; imageservice requires a writable community-data"
      fi
      ;;
    real-files)
      [[ "$IMAGE_ACTION" == "copy" ]] \
        || die "IMAGE_MODE=mount cannot be used when IMAGE_DIR is a real directory; use IMAGE_MODE=auto or copy"
      warn "IMAGE_DIR is a real directory; it will be copied into ./images"
      ;;
    *)
      die "could not determine image layout for $OLD_IMAGE_PATH"
      ;;
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
  printf 'old project: %s\nold HTTP port: %s\nold public data: %s (reused, not copied)\nimage mode: %s\nimage layout: %s\nimage action: %s\nnew project: %s\nfinal: %s\n' \
    "$OLD_PROJECT" "$OLD_HTTP_PORT" "$OLD_PUBLIC_DATA_DIR" "$IMAGE_MODE" "$IMAGE_LAYOUT" "$IMAGE_ACTION" "$NEW_PROJECT" "$TCAS_URL"
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
    run_in "$INFRA_DIR" bash init.sh -y \
      --keycloak-public-url "$KEYCLOAK_PUBLIC_URL" \
      --elasticsearch-host-port "$NEW_ES_PORT"
    [[ -f "$INFRA_DIR/.env" ]] \
      || die "infra init did not write $INFRA_DIR/.env"
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
    set_env "$env_file" PUBLIC_SERVER "$TCAS_URL"
    set_env "$env_file" KEYCLOAK_PUBLIC_URL "$KEYCLOAK_PUBLIC_URL"
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
  if [[ "$IMAGE_ACTION" == "mount" ]]; then
    compose_file="$compose_file:compose.media.yml"
  fi
  local public_data="${OLD_PUBLIC_DATA_DIR:-./data/public}"
  local private_data="${OLD_PRIVATE_DATA_DIR:-./data/private}"
  local image_dir="${NEW_IMAGE_DIR:-./images}"
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
PUBLIC_SERVER=$TCAS_URL
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

write_media_override() {
  [[ "$IMAGE_ACTION" == "mount" ]] || return 0
  [[ -n "$IMAGE_MOUNT_SOURCE" ]] || die \
    "IMAGE_ACTION=mount requires IMAGE_MOUNT_SOURCE"
  local file="$NEW_SPECIES_DIR/compose.media.yml"
  if (( DRY_RUN )); then
    log "would write $file with $IMAGE_MOUNT_SOURCE mounted read-only"
    return
  fi
  cat > "$file" <<EOF
services:
  imageservice:
    volumes:
      - ${IMAGE_MOUNT_SOURCE}:${IMAGE_MOUNT_SOURCE}:ro

  phenotypeservice:
    volumes:
      - ${IMAGE_MOUNT_SOURCE}:${IMAGE_MOUNT_SOURCE}:ro
EOF
  log "wrote $file"
}

copy_images() {
  local delete_flag=""
  [[ "${1:-}" == "delete" ]] && delete_flag="--delete"
  local dest="$NEW_SPECIES_DIR/images"

  case "$IMAGE_ACTION" in
    link)
      [[ -n "$IMAGE_TARGET" && -d "$IMAGE_TARGET" ]] \
        || die "image link target not found: $IMAGE_TARGET"
      if [[ -L "$dest" ]]; then
        run rm -f "$dest"
      elif [[ -e "$dest" ]]; then
        die "$dest exists and is not a symlink; refusing to replace it"
      fi
      run ln -s "$IMAGE_TARGET" "$dest"
      ;;
    mount)
      run mkdir -p "$dest"
      run rsync -a $delete_flag "$OLD_IMAGE_PATH/" "$dest/"
      ;;
    direct)
      # IMAGE_DIR is an absolute path and is used directly; nothing is copied.
      ;;
    copy)
      [[ -n "$IMAGE_TARGET" && -d "$IMAGE_TARGET" ]] \
        || die "image copy target not found: $IMAGE_TARGET"
      run mkdir -p "$dest"
      run rsync -a $delete_flag --copy-links "$IMAGE_TARGET/" "$dest/"
      ;;
    *)
      die "unknown image action: $IMAGE_ACTION"
      ;;
  esac
}

copy_files() {
  local delete_flag=""
  [[ "${1:-}" == "delete" ]] && delete_flag="--delete"
  local dir src
  copy_images "${1:-}"
  for dir in data oba; do
    src="$OLD_SPECIES_DIR/$dir"
    [[ -d "$src" ]] || continue
    case "$src" in
      "$OLD_SPECIES_DIR"/*) ;;
      *) die "refusing to copy outside the old checkout: $src" ;;
    esac
    run mkdir -p "$NEW_SPECIES_DIR/$dir"
    run rsync -a $delete_flag "$src/" "$NEW_SPECIES_DIR/$dir/"
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
  local extra_realms=""
  if (( ! DRY_RUN )); then
    extra_realms=$(infra_compose exec -T mysql sh -c \
      "exec mysql -N -s -uroot -p\"\$MYSQL_ROOT_PASSWORD\" -e \"SELECT COUNT(*) FROM keycloak.REALM WHERE NAME NOT IN ('master', '$REALM');\"" \
      2>/dev/null || true)
    extra_realms=${extra_realms//[^0-9]/}
  fi
  if [[ -n "$extra_realms" && "$extra_realms" != "0" ]]; then
    die "infra Keycloak already hosts $extra_realms realm(s) other than master and $REALM; refusing to replace its database"
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
    "$TCAS_URL"
}

setup_directus() {
  run_in "$NEW_SPECIES_DIR" docker compose run --rm setup-directus
}

start_new() {
  run_in "$NEW_SPECIES_DIR" docker compose up -d --wait
}

cmd_prepare() {
  load_context
  cmd_check
  run mkdir -p "$BACKUP_DIR"
  clone_repos
  init_infra
  write_new_env
  write_media_override
  log "prepare complete"
  cat <<EOF

The new infra and configuration are ready. No data has been copied yet.
The old site is still live.

Next:
  1. Review the final vhost from ./migrate.sh apache.
  2. Run: ./migrate.sh transfer in the announced window; it copies all data once.

Final URL:       $TCAS_URL
EOF
}

cmd_transfer() {
  load_context
  require_admin
  case "$ES_MODE" in
    snapshot|rebuild) ;;
    *) die "ES_MODE must be snapshot or rebuild" ;;
  esac
  [[ -f "$NEW_SPECIES_DIR/.env" ]] || die "prepare has not run: $NEW_SPECIES_DIR/.env is missing"
  [[ -n "$NEW_INFRA_MYSQL_PASSWORD" ]] || NEW_INFRA_MYSQL_PASSWORD=$(env_get "$INFRA_DIR/.env" MYSQL_ROOT_PASSWORD || true)
  [[ -n "$NEW_INFRA_MYSQL_PASSWORD" ]] || die "infra .env has no MYSQL_ROOT_PASSWORD"

  log "copying final data while the old site stays live"
  old_compose_run up -d --wait mysql keycloak es
  new_compose_run stop

  import_directus "$BACKUP_DIR/directus-final.sql"

  log "final Keycloak copy"
  copy_keycloak_db final

  log "final files and uploads"
  write_media_override
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
  cat <<EOF

Final data is in the new stack, running on 127.0.0.1:$NEW_HTTP_PORT.
The old site is still live.

Switch 443 to the new stack:
  replace the 443 vhost with <NEW_WORKSPACE>/apache-final.conf
  apachectl configtest
  systemctl reload apache2

Then run: ./migrate.sh verify
After verification: ./migrate.sh finish
EOF
}

cmd_verify() {
  load_context
  log "final checks"
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

After verification, stop the old stack:
  ./migrate.sh finish
EOF
}

cmd_finish() {
  load_context
  log "stopping the old stack; volumes are kept"
  old_compose_run stop
  cat <<EOF

Old stack stopped. Its volumes and $BACKUP_DIR are kept for retention and
rollback. Do not run cleanup until the retention period ends.
EOF
}

cmd_rollback() {
  load_context

  local new_state
  if (( KEEP_NEW )); then
    log "keeping the new stacks running"
    log "starting the new infra stack"
    run_in "$INFRA_DIR" docker compose up -d --wait
    new_compose_run up -d --wait
    new_state="The new species and infra stacks are still running; the new app is on 127.0.0.1:$NEW_HTTP_PORT for local diagnosis."
  else
    log "stopping the new stack"
    new_compose_run stop
    new_state="The new species and infra stacks are stopped; their volumes were kept for a retry."
  fi

  log "starting the old stack"
  old_compose_run up -d --wait

  if (( ! KEEP_NEW )); then
    log "stopping the new infra stack"
    infra_compose_run stop
  fi

  cat <<EOF

$new_state

Restore the old 443 vhost:
  / -> 127.0.0.1:$OLD_HTTP_PORT, and /ibb/keycloak through the old stack.

Then reload Apache:

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
    --keep-new) KEEP_NEW=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) COMMAND=$1; shift ;;
  esac
done

[[ -n "$COMMAND" ]] || { usage; exit 1; }
if (( KEEP_NEW )) && [[ "$COMMAND" != "rollback" ]]; then
  die "--keep-new is only valid with rollback"
fi

case "$COMMAND" in
  init) cmd_init ;;
  apache) cmd_apache ;;
  check) cmd_check ;;
  prepare) cmd_prepare ;;
  transfer) cmd_transfer ;;
  verify) cmd_verify ;;
  rollback) cmd_rollback ;;
  finish) cmd_finish ;;
  cleanup) cmd_cleanup ;;
  *) die "unknown command: $COMMAND (run --help)" ;;
esac
