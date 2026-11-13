#!/usr/bin/env bash

set -eo pipefail

PASSWORD_LENGTH=16
FORCE=false
YES=false
LOCAL=false
MAIN_SPECIES=
PUBLIC_SERVER=
PORTAL_SERVER=
PORTAL_INTERNAL_URL=
PORTAL_DIR=
INFRA_DIR=
HTTP_PORT=
CONTAINER_PREFIX=
DIRECTUS_DB_DATABASE=
KEYCLOAK_REALM=
KEYCLOAK_CLIENT_ID=
KEYCLOAK_CLIENT_SECRET=
COCO_USERNAME=
COCO_PASSWORD=
KEYCLOAK_REALM_MODE=

DEFAULT_HTTP_PORT=9090
DEFAULT_PORTAL_DIR="../emobase-portal-deploy"
DEFAULT_INFRA_DIR="../emobase-infra"
DEFAULT_INFRA_NETWORK="emobase-infra"

fatal() {
  >&2 echo "❌ $1"
  exit 1
}

# ask VAR "label" "default"
# Keeps an explicit flag or discovered value; otherwise asks with a default.
# --yes uses the default without prompting. A non-terminal without --yes aborts.
ask() {
  local var="$1" label="$2" default="$3" value
  [[ -n "${!var:-}" ]] && return 0
  if [[ "$YES" == true ]]; then
    printf -v "$var" '%s' "$default"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    fatal "Cannot ask for ${label}: stdin is not a terminal. Pass --yes or the matching option."
  fi
  if [[ -n "$default" ]]; then
    read -rp "${label} [${default}]: " value
  else
    read -rp "${label}: " value
  fi
  printf -v "$var" '%s' "${value:-$default}"
}

# detect_host_ip prints the address used for the default route. It is the
# server's reachable interface address, not necessarily its internet-facing
# address when the host is behind NAT.
detect_host_ip() {
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{
    for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }
  }')
  if [[ -z "$ip" ]]; then
    ip=$(hostname -I 2>/dev/null | awk '{
      for (i = 1; i <= NF; i++) if ($i !~ /^127\./) { print $i; exit }
    }')
  fi
  if [[ -z "$ip" ]] && command -v ipconfig >/dev/null 2>&1; then
    ip=$(ipconfig getifaddr en0 2>/dev/null || true)
  fi
  printf '%s\n' "$ip"
}

is_private_ip() {
  [[ "$1" =~ ^10\. ]] || [[ "$1" =~ ^192\.168\. ]] || \
    [[ "$1" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]]
}

generate_secret_key() {
  length="${1:-32}"
  local key # Needed to avoid pipefail
  key=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$length" || true)
  echo "$key"
}

generate_password() {
  length="${1:-$PASSWORD_LENGTH}"

  upper=$(LC_ALL=C tr -dc 'A-Z' </dev/urandom | head -c1 || true)
  lower=$(LC_ALL=C tr -dc 'a-z' </dev/urandom | head -c1 || true)
  digit=$(LC_ALL=C tr -dc '0-9' </dev/urandom | head -c1 || true)
  symbol=$(LC_ALL=C tr -dc '_+=-' </dev/urandom | head -c1 || true)

  rest_length=$((length - 4))
  rest=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$rest_length" || true)

  # Shuffle safely using awk (portable)
  printf "%s\n" "$upper$lower$digit$symbol$rest" | \
    awk 'BEGIN{srand()} {for(i=1;i<=length;i++) a[i]=substr($0,i,1)}
         END{for(i=1;i<=length;i++){j=int(rand()*length)+1; tmp=a[i]; a[i]=a[j]; a[j]=tmp}
             for(i=1;i<=length;i++) printf a[i]; printf "\n"}'
}

# Extract the port from an http(s) URL. Used to build the internal portal URL
# for local mode (host.docker.internal:<portal-port>).
url_port() {
  local url="$1"
  if [[ "$url" =~ ^https?://[^/:]+:([0-9]+)(/|$) ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$url" == https://* ]]; then
    echo 443
  else
    echo 80
  fi
}

# True when the URL points at localhost/127.0.0.1, where a container cannot
# reach the host's published ports without host.docker.internal.
is_loopback_url() {
  [[ "$1" =~ ^https?://(localhost|127\.0\.0\.1)([:/]|$) ]]
}

# Read a value from a dotenv file without sourcing it (so the portal .env's
# secrets never enter this process).
read_env_value() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  local value
  value=$(grep -E "^${key}=" "$file" | tail -n1 | cut -d= -f2- | tr -d '\r') || return 1
  [[ -n "$value" ]] || return 1
  echo "$value"
}

portal_public_server_from_dir() {
  local dir="$1"
  [[ -n "$dir" ]] || return 1
  read_env_value "${dir}/.env" PUBLIC_SERVER
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -s|--species)
      MAIN_SPECIES="$2"
      shift 2
      ;;
    --public-server)
      PUBLIC_SERVER="$2"
      shift 2
      ;;
    --http-port)
      HTTP_PORT="$2"
      shift 2
      ;;
    --portal-server)
      PORTAL_SERVER="$2"
      shift 2
      ;;
    --portal-internal-url)
      PORTAL_INTERNAL_URL="$2"
      shift 2
      ;;
    --portal-dir)
      PORTAL_DIR="$2"
      shift 2
      ;;
    --infra-dir)
      INFRA_DIR="$2"
      shift 2
      ;;
    --directus-db)
      DIRECTUS_DB_DATABASE="$2"
      shift 2
      ;;
    --keycloak-realm)
      KEYCLOAK_REALM="$2"
      shift 2
      ;;
    --keycloak-client-id)
      KEYCLOAK_CLIENT_ID="$2"
      shift 2
      ;;
    --keycloak-client-secret)
      KEYCLOAK_CLIENT_SECRET="$2"
      shift 2
      ;;
    --coco-username)
      COCO_USERNAME="$2"
      shift 2
      ;;
    --coco-password)
      COCO_PASSWORD="$2"
      shift 2
      ;;
    --container-prefix)
      CONTAINER_PREFIX="$2"
      shift 2
      ;;
    -f|--force)
      FORCE=true
      shift
      ;;
    -p|--print)
      PRINT=true
      shift
      ;;
    -y|--yes)
      YES=true
      shift
      ;;
    --local)
      LOCAL=true
      shift
      ;;
    *)
      echo "Usage: $0 [-f|--force] [-p|--print] [-y|--yes] [--local] [-s|--species SPECIES] [--public-server URL] [--http-port PORT] [--portal-server URL] [--portal-internal-url URL] [--portal-dir DIR] [--infra-dir DIR] [--directus-db NAME] [--keycloak-realm join:REALM|new:REALM] [--keycloak-client-id ID] [--keycloak-client-secret SECRET] [--coco-username USER] [--coco-password PASSWORD] [--container-prefix PREFIX]"
      echo "Without options, asks each value in order and shows its default."
      echo "The species code is required and has no default; for example Tcas."
      echo "  -s, --species       4-letter species code (e.g. Tcas, Dmel, Ptep)"
      echo "  --public-server     Public server address (default: http://localhost:<http-port>)"
      echo "  --http-port         Host port for nginx (default: ${DEFAULT_HTTP_PORT})"
      echo "  --portal-server     Public portal origin used by browsers (genomics, JBrowse2, BLAST)"
      echo "  --portal-internal-url"
      echo "                      Portal origin used from inside containers (BLAST proxy, SSR)"
      echo "  --portal-dir        Portal checkout whose .env holds PUBLIC_SERVER"
      echo "                      (default: ${DEFAULT_PORTAL_DIR} when present)"
      echo "  --infra-dir         emobase-infra checkout whose .env holds the shared"
      echo "                      MySQL/Keycloak secrets (default: ${DEFAULT_INFRA_DIR} when present)"
      echo "  --directus-db       Directus database name (default: directus_<species>)"
      echo "  --keycloak-realm    join:REALM to reuse an existing realm, new:REALM"
      echo "                      to create one, or a plain name for a new realm"
      echo "  --keycloak-client-id"
      echo "                      Client ID (default: emobase-<species>-client)"
      echo "  --keycloak-client-secret"
      echo "                      Client secret (copied when joining, generated when new)"
      echo "  --coco-username     Seed user name (default: coco)"
      echo "  --coco-password     Seed user password (copied when joining, generated when new)"
      echo "  --container-prefix  Prefix for docker compose containers (default: current directory)"
      echo "  --local             Use localhost for browser URLs and an internal host URL"
      echo "  -f, --force         Overwrite existing .env file"
      echo "  -y, --yes           Use default values without prompting"
      echo "  -p, --print         Print credentials to screen instead of writing to .env"
      exit 1
      ;;
  esac
done

if [[ "$PRINT" != true ]]; then
  if [[ -f .env ]] && [[ "$FORCE" != true ]]; then
    echo "⚠️  .env file already exists. Use -f to overwrite."
    exit 1
  fi
fi

# Resolve the shared MySQL/Keycloak secrets from emobase-infra. Every species
# uses the same MySQL root password and Keycloak client secret.
if [[ -z "$INFRA_DIR" ]] && [[ -f "${DEFAULT_INFRA_DIR}/.env" ]]; then
  INFRA_DIR="$DEFAULT_INFRA_DIR"
fi
if [[ -z "$INFRA_DIR" ]]; then
  fatal "Shared infrastructure .env not found. Run emobase-infra/init.sh first, or pass --infra-dir DIR."
fi
[[ -f "$INFRA_DIR/.env" ]] || fatal "No .env in ${INFRA_DIR}; run emobase-infra/init.sh first."

MYSQL_ROOT_PASSWORD=$(read_env_value "$INFRA_DIR/.env" MYSQL_ROOT_PASSWORD || true)
[[ -n "$MYSQL_ROOT_PASSWORD" ]] \
  || fatal "${INFRA_DIR}/.env has no MYSQL_ROOT_PASSWORD; re-run emobase-infra/init.sh."
INFRA_KEYCLOAK_HOST_PORT=$(read_env_value "$INFRA_DIR/.env" KEYCLOAK_HOST_PORT || true)
INFRA_KEYCLOAK_HOST_PORT="${INFRA_KEYCLOAK_HOST_PORT:-8081}"
INFRA_KEYCLOAK_PUBLIC_URL=$(read_env_value "$INFRA_DIR/.env" KEYCLOAK_PUBLIC_URL || true)
INFRA_KEYCLOAK_PUBLIC_URL="${INFRA_KEYCLOAK_PUBLIC_URL:-http://localhost:${INFRA_KEYCLOAK_HOST_PORT}/keycloak}"
INFRA_KEYCLOAK_INTERNAL_URL=$(read_env_value "$INFRA_DIR/.env" KEYCLOAK_INTERNAL_URL || true)
INFRA_KEYCLOAK_INTERNAL_URL="${INFRA_KEYCLOAK_INTERNAL_URL:-http://keycloak:8080/keycloak}"

INFRA_NETWORK=$(read_env_value "$INFRA_DIR/.env" EMOBASE_INFRA_NETWORK || true)
INFRA_NETWORK="${INFRA_NETWORK:-$DEFAULT_INFRA_NETWORK}"

>&2 echo "🔗 Using local MySQL/Keycloak configuration from ${INFRA_DIR}/.env"

# Ask for inputs
if [[ -z "$MAIN_SPECIES" ]]; then
  if [[ "$YES" == true ]]; then
    fatal "MAIN_SPECIES is required; pass --species CODE (for example Tcas)"
  fi
  if [[ ! -t 0 ]]; then
    fatal "Cannot ask for the species code: stdin is not a terminal. Pass --species CODE (for example Tcas)."
  fi
  while [[ -z "$MAIN_SPECIES" ]]; do
    read -rp "🧬 Species code (for example Tcas): " MAIN_SPECIES
    [[ -z "$MAIN_SPECIES" ]] && >&2 echo "   A species code is required."
  done
fi
species_slug=$(printf '%s' "$MAIN_SPECIES" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_')
species_slug="${species_slug:-species}"

ask HTTP_PORT "🔌 Host port for the web UI" "$DEFAULT_HTTP_PORT"
[[ "$HTTP_PORT" =~ ^[0-9]+$ ]] && (( 10#$HTTP_PORT >= 1 && 10#$HTTP_PORT <= 65535 )) \
  || fatal "HTTP_PORT must be a number between 1 and 65535"
host_ip=
if [[ "$LOCAL" != true ]]; then
  host_ip=$(detect_host_ip)
fi
DEFAULT_PUBLIC_SERVER="http://localhost:${HTTP_PORT}"
if [[ "$LOCAL" != true ]] && [[ -n "$host_ip" ]]; then
  DEFAULT_PUBLIC_SERVER="http://${host_ip}:${HTTP_PORT}"
  if [[ -z "$PUBLIC_SERVER" ]] && is_private_ip "$host_ip"; then
    >&2 echo "⚠️  Detected host address ${host_ip}; use the public IP or domain if this server is behind NAT."
  fi
fi

if [[ "$LOCAL" == true ]] && [[ -z "$PUBLIC_SERVER" ]]; then
  PUBLIC_SERVER="http://localhost:${HTTP_PORT}"
  >&2 echo "🏠 Local mode: using ${PUBLIC_SERVER}"
fi
ask PUBLIC_SERVER "🌐 Public server address" "$DEFAULT_PUBLIC_SERVER"
PUBLIC_SERVER="${PUBLIC_SERVER%/}"
[[ -z "$PUBLIC_SERVER" ]] && fatal "PUBLIC_SERVER cannot be empty"

if [[ -z "$PORTAL_SERVER" ]]; then
  # Prefer the portal checkout next to this repository. Using its .env avoids
  # copying PUBLIC_SERVER by hand and keeps the two values identical.
  if [[ -z "$PORTAL_DIR" ]] && [[ -f "${DEFAULT_PORTAL_DIR}/.env" ]]; then
    PORTAL_DIR="$DEFAULT_PORTAL_DIR"
  fi

  if [[ -n "$PORTAL_DIR" ]]; then
    PORTAL_SERVER=$(portal_public_server_from_dir "$PORTAL_DIR" || true)
    [[ -n "$PORTAL_SERVER" ]] \
      || fatal "Could not read PUBLIC_SERVER from ${PORTAL_DIR}/.env; pass --portal-server URL"
    >&2 echo "🔗 Using portal URL from ${PORTAL_DIR}/.env"
  elif [[ "$LOCAL" == true ]]; then
    PORTAL_SERVER="http://localhost:9080"
  elif [[ "$YES" == true ]]; then
    fatal "PORTAL_SERVER is required; pass --portal-server URL or --portal-dir DIR"
  else
    if [[ ! -t 0 ]]; then
      fatal "Cannot ask for the portal origin: stdin is not a terminal. Pass --portal-server URL or --portal-dir DIR."
    fi
    default_portal="http://localhost:9080"
    if [[ -n "$host_ip" ]]; then
      default_portal="http://${host_ip}:9080"
    fi
    while [[ -z "$PORTAL_SERVER" ]]; do
      read -rp "🌐 Portal origin serving genomics/JBrowse2/BLAST [${default_portal}]: " PORTAL_SERVER
      PORTAL_SERVER="${PORTAL_SERVER:-$default_portal}"
    done
  fi
fi
PORTAL_SERVER="${PORTAL_SERVER%/}"
[[ -z "$PORTAL_SERVER" ]] && fatal "PORTAL_SERVER cannot be empty"

if [[ "$LOCAL" == true ]]; then
  default_internal="http://host.docker.internal:$(url_port "$PORTAL_SERVER")"
else
  default_internal="$PORTAL_SERVER"
fi
ask PORTAL_INTERNAL_URL "🔗 Portal origin used from inside containers" "$default_internal"
PORTAL_INTERNAL_URL="${PORTAL_INTERNAL_URL%/}"
[[ -z "$PORTAL_INTERNAL_URL" ]] && fatal "PORTAL_INTERNAL_URL cannot be empty"

if [[ "$PORTAL_SERVER" == *localhost* || "$PORTAL_SERVER" == *127.0.0.1* ]] \
  && [[ "$PORTAL_INTERNAL_URL" == "$PORTAL_SERVER" ]]; then
  >&2 echo "⚠️  PORTAL_SERVER points at localhost and PORTAL_INTERNAL_URL is the same."
  >&2 echo "   Containers cannot reach the portal there. Use --local, or set"
  >&2 echo "   --portal-internal-url to an address reachable from inside Docker."
fi

ask DIRECTUS_DB_DATABASE "🗄️  Directus database" "directus_${species_slug}"
[[ "$DIRECTUS_DB_DATABASE" =~ ^[A-Za-z0-9_]+$ ]] \
  || fatal "DIRECTUS_DB_DATABASE may only contain letters, digits and underscores"

ask CONTAINER_PREFIX "📦 Compose project/container prefix" "$species_slug"
[[ "$CONTAINER_PREFIX" =~ ^[a-zA-Z0-9_.-]+$ ]] \
  || fatal "CONTAINER_PREFIX may only contain letters, digits, dot, underscore and hyphen"

# ── Keycloak realm choice ───────────────────────────────────────────────────
# Realms are owned by the portal or by the species that created them. This
# species can join any realm with locally available credentials or create a
# new independent realm. Infra does not own a realm.
REALM_NAMES=()
REALM_CLIENTS=()
REALM_SECRETS=()
REALM_COCO_USERS=()
REALM_COCO_PASSES=()
REALM_SOURCES=()

realm_index_of() {
  local name="$1" i
  for ((i = 0; i < ${#REALM_NAMES[@]}; i++)); do
    if [[ "${REALM_NAMES[$i]}" == "$name" ]]; then
      printf '%s\n' "$i"
      return 0
    fi
  done
  printf '%s\n' "-1"
}

add_realm_option() {
  local file="$1" label="$2" realm client secret user pass idx
  realm=$(read_env_value "$file" KEYCLOAK_REALM || true)
  [[ -n "$realm" ]] || return 0
  idx=$(realm_index_of "$realm")
  [[ "$idx" == "-1" ]] || return 0
  client=$(read_env_value "$file" KEYCLOAK_CLIENT_ID || true)
  secret=$(read_env_value "$file" KEYCLOAK_CLIENT_SECRET || true)
  user=$(read_env_value "$file" COCO_USERNAME || true)
  pass=$(read_env_value "$file" COCO_PASSWORD || true)
  [[ -n "$client" && -n "$secret" ]] || return 0
  REALM_NAMES+=("$realm")
  REALM_CLIENTS+=("$client")
  REALM_SECRETS+=("$secret")
  REALM_COCO_USERS+=("${user:-coco}")
  REALM_COCO_PASSES+=("$pass")
  REALM_SOURCES+=("$label")
}

portal_candidate="$PORTAL_DIR"
if [[ -z "$portal_candidate" ]] && [[ -f "${DEFAULT_PORTAL_DIR}/.env" ]]; then
  portal_candidate="$DEFAULT_PORTAL_DIR"
fi
if [[ -n "$portal_candidate" ]] && [[ -f "$portal_candidate/.env" ]]; then
  add_realm_option "$portal_candidate/.env" "portal"
fi

workspace_parent="$(dirname "$PWD")"
for env_file in "$workspace_parent"/emobase-deploy*/.env; do
  [[ -f "$env_file" ]] || continue
  [[ "$env_file" == "$PWD/.env" ]] && continue
  label=$(read_env_value "$env_file" MAIN_SPECIES || true)
  [[ -n "$label" ]] || label=$(basename "$(dirname "$env_file")")
  add_realm_option "$env_file" "$label"
done

default_realm="emobase-${species_slug}"
ASK_NEW_DETAILS=false
if [[ -z "$KEYCLOAK_REALM" ]]; then
  if [[ "$YES" == true ]]; then
    if [[ ${#REALM_NAMES[@]} -gt 0 ]]; then
      KEYCLOAK_REALM="join:${REALM_NAMES[0]}"
    else
      KEYCLOAK_REALM="new:${default_realm}"
    fi
  else
    if [[ ! -t 0 ]]; then
      fatal "Cannot ask for the Keycloak realm: stdin is not a terminal. Pass --keycloak-realm join:REALM or new:REALM."
    fi
    >&2 echo
    >&2 echo "🔐 Keycloak realm for this species:"
    if [[ ${#REALM_NAMES[@]} -gt 0 ]]; then
      for ((i = 0; i < ${#REALM_NAMES[@]}; i++)); do
        >&2 echo "   $((i + 1))) Realm '${REALM_NAMES[$i]}' — used by ${REALM_SOURCES[$i]}"
      done
      new_choice=$((${#REALM_NAMES[@]} + 1))
      >&2 echo "   ${new_choice}) Create a new independent realm [${default_realm}]"
      while true; do
        read -rp "Choose [1]: " realm_choice
        realm_choice="${realm_choice:-1}"
        if [[ "$realm_choice" =~ ^[0-9]+$ ]] && (( realm_choice >= 1 && realm_choice <= new_choice )); then
          break
        fi
        >&2 echo "   Enter a number between 1 and ${new_choice}."
      done
      if (( realm_choice == new_choice )); then
        KEYCLOAK_REALM="new:${default_realm}"
        ASK_NEW_DETAILS=true
      else
        idx=$((realm_choice - 1))
        KEYCLOAK_REALM="join:${REALM_NAMES[$idx]}"
      fi
    else
      >&2 echo "   No existing realms found."
      read -rp "New realm name [${default_realm}]: " realm_name
      KEYCLOAK_REALM="new:${realm_name:-$default_realm}"
      ASK_NEW_DETAILS=true
    fi
  fi
fi

case "$KEYCLOAK_REALM" in
  shared)
    if [[ ${#REALM_NAMES[@]} -gt 0 ]]; then
      KEYCLOAK_REALM="join:${REALM_NAMES[0]}"
    else
      KEYCLOAK_REALM="new:${default_realm}"
    fi
    ;;
esac

case "$KEYCLOAK_REALM" in
  join:*)
    join_realm="${KEYCLOAK_REALM#join:}"
    idx=$(realm_index_of "$join_realm")
    if [[ "$idx" == "-1" ]]; then
      if [[ -z "$KEYCLOAK_CLIENT_ID" || -z "$KEYCLOAK_CLIENT_SECRET" ]]; then
        fatal "Realm '${join_realm}' was not found in a local checkout. Pass --keycloak-client-id and --keycloak-client-secret to join it explicitly."
      fi
    else
      KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-${REALM_CLIENTS[$idx]}}"
      KEYCLOAK_CLIENT_SECRET="${KEYCLOAK_CLIENT_SECRET:-${REALM_SECRETS[$idx]}}"
      COCO_USERNAME="${COCO_USERNAME:-${REALM_COCO_USERS[$idx]}}"
      COCO_PASSWORD="${COCO_PASSWORD:-${REALM_COCO_PASSES[$idx]}}"
    fi
    KEYCLOAK_REALM="$join_realm"
    KEYCLOAK_REALM_MODE=joined
    >&2 echo "🔐 Joining existing Keycloak realm '${KEYCLOAK_REALM}'."
    ;;
  new:*)
    KEYCLOAK_REALM="${KEYCLOAK_REALM#new:}"
    KEYCLOAK_REALM_MODE=dedicated
    ;;
  *)
    idx=$(realm_index_of "$KEYCLOAK_REALM")
    if [[ "$idx" != "-1" ]]; then
      KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-${REALM_CLIENTS[$idx]}}"
      KEYCLOAK_CLIENT_SECRET="${KEYCLOAK_CLIENT_SECRET:-${REALM_SECRETS[$idx]}}"
      COCO_USERNAME="${COCO_USERNAME:-${REALM_COCO_USERS[$idx]}}"
      COCO_PASSWORD="${COCO_PASSWORD:-${REALM_COCO_PASSES[$idx]}}"
      KEYCLOAK_REALM_MODE=joined
      >&2 echo "🔐 Joining existing Keycloak realm '${KEYCLOAK_REALM}'."
    else
      KEYCLOAK_REALM_MODE=dedicated
    fi
    ;;
esac

if [[ "$KEYCLOAK_REALM_MODE" == "dedicated" ]]; then
  if [[ "$ASK_NEW_DETAILS" == true ]]; then
    read -rp "New realm name [${KEYCLOAK_REALM}]: " realm_name
    KEYCLOAK_REALM="${realm_name:-$KEYCLOAK_REALM}"
    default_client="emobase-${species_slug}-client"
    read -rp "Client ID [${default_client}]: " client_id
    KEYCLOAK_CLIENT_ID="${client_id:-$default_client}"
  fi
  KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-emobase-${species_slug}-client}"
  KEYCLOAK_CLIENT_SECRET="${KEYCLOAK_CLIENT_SECRET:-$(generate_secret_key 32)}"
  COCO_USERNAME="${COCO_USERNAME:-coco}"
  COCO_PASSWORD="${COCO_PASSWORD:-$(generate_password 24)}"
  >&2 echo "🔐 New Keycloak realm '${KEYCLOAK_REALM}' will be created by emobase species setup."
fi

[[ "$KEYCLOAK_REALM" =~ ^[a-zA-Z0-9_.-]+$ ]] \
  || fatal "Keycloak realm names may only contain letters, digits, dot, underscore and hyphen."
[[ "$KEYCLOAK_CLIENT_ID" =~ ^[a-zA-Z0-9_.-]+$ ]] \
  || fatal "Keycloak client IDs may only contain letters, digits, dot, underscore and hyphen."

KEYCLOAK_PUBLIC_URL="${KEYCLOAK_PUBLIC_URL:-$INFRA_KEYCLOAK_PUBLIC_URL}"
KEYCLOAK_INTERNAL_URL="${KEYCLOAK_INTERNAL_URL:-$INFRA_KEYCLOAK_INTERNAL_URL}"
KEYCLOAK_PUBLIC_URL="${KEYCLOAK_PUBLIC_URL%/}"
KEYCLOAK_INTERNAL_URL="${KEYCLOAK_INTERNAL_URL%/}"
if is_loopback_url "$KEYCLOAK_PUBLIC_URL" \
  && [[ "$PUBLIC_SERVER" != *localhost* && "$PUBLIC_SERVER" != *127.0.0.1* ]]; then
  >&2 echo "⚠️  KEYCLOAK_PUBLIC_URL points at localhost but PUBLIC_SERVER does not."
  >&2 echo "   Set --keycloak-public-url in emobase-infra/init.sh."
fi
if is_loopback_url "$KEYCLOAK_PUBLIC_URL"; then
  INTERNAL_KEYCLOAK_ISSUER="http://host.docker.internal:${INFRA_KEYCLOAK_HOST_PORT}/keycloak/realms/${KEYCLOAK_REALM}"
else
  INTERNAL_KEYCLOAK_ISSUER="${KEYCLOAK_PUBLIC_URL}/realms/${KEYCLOAK_REALM}"
fi

if [[ -z "$DIRECTUS_DB_DATABASE" ]]; then
  DIRECTUS_DB_DATABASE="directus_${species_slug}"
fi
[[ "$DIRECTUS_DB_DATABASE" =~ ^[A-Za-z0-9_]+$ ]] \
  || fatal "DIRECTUS_DB_DATABASE may only contain letters, digits and underscores"

ENV_CONTENT="# 4-letter code of your species (e.g. Tcas, Dmel, Ptep)
MAIN_SPECIES=${MAIN_SPECIES}

# Web UI image
EMOBASE_WEB_IMAGE=ghcr.io/emobase/emobase-web:dev

# The full address to access the app from public, including protocol and port (if not 80 or 443)
PUBLIC_SERVER=${PUBLIC_SERVER}

# Public origin of the portal deployment that serves genomics, JBrowse2 and BLAST
PORTAL_SERVER=${PORTAL_SERVER}

# Portal origin used from inside this stack's containers (BLAST proxy, SSR API
# calls). Use an internal hostname/URL when the portal is on the same Docker
# host; otherwise this may be the same as PORTAL_SERVER.
PORTAL_INTERNAL_URL=${PORTAL_INTERNAL_URL}

# ── Shared infrastructure ───────────────────────────────────────────────────
# MySQL and Keycloak run in the sibling emobase-infra stack. Start it first.
# This stack joins its Docker network; the service names below resolve there.
EMOBASE_INFRA_NETWORK=${INFRA_NETWORK}
DIRECTUS_DB_HOST=mysql
DIRECTUS_DB_PORT=3306
DIRECTUS_DB_USER=root
DIRECTUS_DB_DATABASE=${DIRECTUS_DB_DATABASE}

# Keycloak endpoint/realm/client. The realm is either an existing realm this
# species joined or a new independent realm owned by this checkout.
KEYCLOAK_PUBLIC_URL=${KEYCLOAK_PUBLIC_URL}
KEYCLOAK_INTERNAL_URL=${KEYCLOAK_INTERNAL_URL}
KEYCLOAK_REALM=${KEYCLOAK_REALM}
KEYCLOAK_REALM_MODE=${KEYCLOAK_REALM_MODE}
KEYCLOAK_CLIENT_ID=${KEYCLOAK_CLIENT_ID}

# Internal service URLs used for server-side calls. These must be absolute.
# They fall back to the matching PUBLIC_* URL if omitted.
INTERNAL_API_GENOMICS_SERVICE=${PORTAL_INTERNAL_URL}/api/genomicsservice/v1
INTERNAL_API_PHENOTYPE_SERVICE=http://phenotypeservice:8080
INTERNAL_API_IMAGE_SERVICE=http://imageservice:8080
INTERNAL_API_ONTOLOGY_SERVICE=http://ontologyservice:8080
INTERNAL_API_GO_ANNOTATION_SERVICE=http://goannotationservice:8080
INTERNAL_API_PUBLICATION_SERVICE=http://publicationservice:8080
INTERNAL_API_QUERY_PIPELINE_SERVICE=http://querypipelineservice:8080
# Server-side Keycloak calls go to this server's emobase-infra Keycloak. They
# do not depend on the portal being reachable.
INTERNAL_KEYCLOAK_ISSUER=${INTERNAL_KEYCLOAK_ISSUER}
INTERNAL_DIRECTUS_URL=http://directus:8055

# The port to access the app from localhost
HTTP_PORT=${HTTP_PORT}

# Project name (prefix for containers)
COMPOSE_PROJECT_NAME=${CONTAINER_PREFIX}

# Directory for data that is publicly downloadable at \$PUBLIC_SERVER/download/
PUBLIC_DATA_DIR=./data/public

# Directory for private data used by internal services
PRIVATE_DATA_DIR=./data/private

# Directory for storing uploaded images
IMAGE_DIR=./images

# uid and gid of the user who can write to the image directory
UID=$(id -u)
GID=$(id -g)

# Secrets
# MYSQL_ROOT_PASSWORD is shared with emobase-infra. KEYCLOAK_CLIENT_SECRET
# belongs to this species' chosen realm.
SSR_OIDC_SESSION_SECRET=$(generate_secret_key 48)
KEYCLOAK_CLIENT_SECRET=${KEYCLOAK_CLIENT_SECRET}
DIRECTUS_SECRET=$(generate_secret_key 32)
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}

# Credentials
DIRECTUS_ADMIN_EMAIL=admin@emobase.org
DIRECTUS_ADMIN_PASSWORD=$(generate_password)

# Seed Keycloak user. For a joined realm these are copied from the owner; for
# a new realm the password is temporary and must be changed on first login.
COCO_USERNAME=${COCO_USERNAME}
COCO_PASSWORD=${COCO_PASSWORD}"

if [[ "$PRINT" == true ]]; then
  echo "$ENV_CONTENT"
else
  printf '%s\n' "$ENV_CONTENT" > .env
  chmod 600 .env
  >&2 echo "✅ .env file generated successfully"
  >&2 echo "   Species URL:  ${PUBLIC_SERVER}"
  >&2 echo "   Portal URL:   ${PORTAL_SERVER}"
  >&2 echo "   Internal URL: ${PORTAL_INTERNAL_URL}"
  >&2 echo "   Directus DB:  ${DIRECTUS_DB_DATABASE}"
  >&2 echo "   Keycloak URL: ${KEYCLOAK_PUBLIC_URL}"
  >&2 echo "   Keycloak realm: ${KEYCLOAK_REALM} (${KEYCLOAK_REALM_MODE})"
  >&2 echo
  >&2 echo "Next:"
  >&2 echo "  1. Make sure emobase-infra is running."
  >&2 echo "  2. Create or update this species' Keycloak realm and origin:"
  >&2 echo "       ${INFRA_DIR}/scripts/create-realm.sh \\"
  >&2 echo "         --realm ${KEYCLOAK_REALM} --origin ${PUBLIC_SERVER} \\"
  >&2 echo "         --client-id ${KEYCLOAK_CLIENT_ID} \\"
  >&2 echo "         --client-secret '${KEYCLOAK_CLIENT_SECRET}' \\"
  >&2 echo "         --coco-username ${COCO_USERNAME} --coco-password '${COCO_PASSWORD}' \\"
  >&2 echo "         --keep-password --quiet"
  >&2 echo "     (emobase species setup, up or bootstrap does this automatically.)"
  >&2 echo "  3. Create this species' Directus database:"
  >&2 echo "       ${INFRA_DIR}/scripts/create-database.sh ${DIRECTUS_DB_DATABASE}"
  >&2 echo "  4. docker compose run --rm setup-directus"
  >&2 echo "  5. docker compose up -d --wait"
fi
