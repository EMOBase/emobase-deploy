#!/usr/bin/env bash

set -eo pipefail

INIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/species-env.sh
source "$INIT_DIR/lib/species-env.sh"

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
KEYCLOAK_PUBLIC_URL=
KEYCLOAK_INTERNAL_URL=
COCO_USERNAME=
COCO_PASSWORD=
EMOBASE_ES_INDEX_PREFIX=

DEFAULT_HTTP_PORT=9090
DEFAULT_PORTAL_DIR="../portal"
DEFAULT_INFRA_DIR="../infra"
DEFAULT_INFRA_NETWORK="emobase-infra"

fatal() {
  >&2 echo "❌ $1"
  exit 1
}

# ask VAR "label" "default" [VALIDATOR] [ERROR]
# Keeps an explicit flag or discovered value; otherwise asks with a default.
# --yes uses the default without prompting. An invalid explicit or default
# value is fatal; an invalid interactive answer is rejected and asked again.
# A non-terminal without --yes aborts.
ask() {
  local var="$1" label="$2" default="$3" validator="${4:-}" error="${5:-Invalid value}" value
  if [[ -n "${!var:-}" ]]; then
    if [[ -n "$validator" ]] && ! "$validator" "${!var}"; then
      fatal "$error"
    fi
    return 0
  fi
  if [[ "$YES" == true ]]; then
    printf -v "$var" '%s' "$default"
    if [[ -n "$validator" ]] && ! "$validator" "$default"; then
      fatal "$error"
    fi
    return 0
  fi
  if [[ ! -t 0 ]]; then
    fatal "Cannot ask for ${label}: stdin is not a terminal. Pass --yes or the matching option."
  fi
  while true; do
    if [[ -n "$default" ]]; then
      read -rp "${label} [${default}]: " value
    else
      read -rp "${label}: " value
    fi
    value="${value:-$default}"
    if [[ -z "$validator" ]] || "$validator" "$value"; then
      printf -v "$var" '%s' "$value"
      return 0
    fi
    >&2 echo "❌ $error"
  done
}

# read_value "label" "default" [VALIDATOR] [ERROR]
# Always prompts, even when the target already has a value, and prints the
# accepted value to stdout. Used for follow-up questions whose default is
# computed at the prompt site.
read_value() {
  local label="$1" default="$2" validator="${3:-}" error="${4:-Invalid value}" value
  while true; do
    if [[ -n "$default" ]]; then
      read -rp "${label} [${default}]: " value
    else
      read -rp "${label}: " value
    fi
    value="${value:-$default}"
    if [[ -z "$validator" ]] || "$validator" "$value"; then
      printf '%s\n' "$value"
      return 0
    fi
    >&2 echo "❌ $error"
  done
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

valid_url() {
  local value="$1"
  while [[ "$value" == */ ]]; do
    value="${value%/}"
  done
  [[ "$value" =~ ^https?://[^/]+ ]]
}

valid_database() {
  [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]
}

valid_container_prefix() {
  [[ "$1" =~ ^[a-zA-Z0-9_.-]+$ ]]
}

valid_es_prefix() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9_-]*$ ]] && [[ "$1" != "genomics" ]]
}

valid_keycloak_name() {
  [[ "$1" =~ ^[a-zA-Z0-9_.-]+$ ]]
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
    --keycloak-public-url)
      KEYCLOAK_PUBLIC_URL="$2"
      shift 2
      ;;
    --keycloak-internal-url)
      KEYCLOAK_INTERNAL_URL="$2"
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
    --es-index-prefix)
      EMOBASE_ES_INDEX_PREFIX="$2"
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
      echo "Usage: $0 [-f|--force] [-p|--print] [-y|--yes] [--local] [-s|--species SPECIES] [--public-server URL] [--http-port PORT] [--portal-server URL] [--portal-internal-url URL] [--portal-dir DIR] [--infra-dir DIR] [--directus-db NAME] [--keycloak-public-url URL] [--keycloak-internal-url URL] [--keycloak-realm REALM] [--keycloak-client-id ID] [--keycloak-client-secret SECRET] [--coco-username USER] [--coco-password PASSWORD] [--container-prefix PREFIX] [--es-index-prefix PREFIX]"
      echo "Without options, asks each value in order and shows its default."
      echo "The species code is required and has no default; for example Tcas."
      echo "  -s, --species       4-letter species code (e.g. Tcas, Dmel, Ptep)"
      echo "  --public-server     Public server address (default: http://localhost:<http-port>)"
      echo "  --http-port         Host port for nginx (default: ${DEFAULT_HTTP_PORT})"
      echo "  --portal-server     Public portal origin used by browsers (genomics, JBrowse2, BLAST)"
      echo "  --portal-internal-url"
      echo "                      Override the derived container-facing portal origin"
      echo "                      (default: http://host.docker.internal:<portal port>"
      echo "                      when the portal is local; unset for a remote portal)"
      echo "  --portal-dir        Portal checkout whose .env holds PUBLIC_SERVER"
      echo "                      (default: ${DEFAULT_PORTAL_DIR} when present)"
      echo "  --infra-dir         infra checkout whose .env holds the shared MySQL"
      echo "                      password and network (default: ${DEFAULT_INFRA_DIR} when present)"
      echo "  --directus-db       Directus database name (default: directus_<species>)"
      echo "  --keycloak-public-url"
      echo "                      Browser-facing Keycloak base URL (default: the"
      echo "                      portal checkout's KEYCLOAK_PUBLIC_URL)"
      echo "  --keycloak-internal-url"
      echo "                      Optional container-facing Keycloak base URL"
      echo "  --keycloak-realm    Existing realm, created on the portal host"
      echo "  --keycloak-client-id"
      echo "                      Existing client ID from the portal"
      echo "  --keycloak-client-secret"
      echo "                      Existing client secret from the portal"
      echo "  --coco-username     Seed user name (default: coco)"
      echo "  --coco-password     Seed user password from the portal"
      echo "  --container-prefix  Prefix for docker compose containers (default: current directory)"
      echo "  --es-index-prefix   Prefix for this species' Elasticsearch indices"
      echo "                      (default: <species>)"
      echo "                      Index names become <prefix>-<service>-..."
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

# Resolve the shared MySQL password and Docker network from emobase-infra.
# Keycloak values are created on the portal and passed in by the operator.
if [[ -z "$INFRA_DIR" ]] && [[ -f "${DEFAULT_INFRA_DIR}/.env" ]]; then
  INFRA_DIR="$DEFAULT_INFRA_DIR"
fi
if [[ -z "$INFRA_DIR" ]]; then
  fatal "Shared infrastructure .env not found. Run the infra checkout's init.sh first, or pass --infra-dir DIR."
fi
[[ -f "$INFRA_DIR/.env" ]] || fatal "No .env in ${INFRA_DIR}; run the infra checkout's init.sh first."

MYSQL_ROOT_PASSWORD=$(read_env_value "$INFRA_DIR/.env" MYSQL_ROOT_PASSWORD || true)
[[ -n "$MYSQL_ROOT_PASSWORD" ]] \
  || fatal "${INFRA_DIR}/.env has no MYSQL_ROOT_PASSWORD; re-run the infra checkout's init.sh."

INFRA_NETWORK=$(read_env_value "$INFRA_DIR/.env" EMOBASE_INFRA_NETWORK || true)
INFRA_NETWORK="${INFRA_NETWORK:-$DEFAULT_INFRA_NETWORK}"

>&2 echo "🔗 Using the shared MySQL password and network from ${INFRA_DIR}/.env"

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

# Tcas has its own Compose overlay for OBA, Ontoscope and the extended
# Swagger UI. Keep the base file first; the overlay only adds to it. Recording
# the files in .env makes plain `docker compose` commands and the emobase CLI
# use them too.
COMPOSE_FILES="compose.yml"
if [[ -f "compose.${species_slug}.yml" ]]; then
  COMPOSE_FILES="${COMPOSE_FILES}:compose.${species_slug}.yml"
fi
COMPOSE_CMD="docker compose"
if [[ "$COMPOSE_FILES" != "compose.yml" ]]; then
  COMPOSE_CMD="docker compose -f ${COMPOSE_FILES//:/ -f }"
fi

ask HTTP_PORT "🔌 Host port for the web UI" "$DEFAULT_HTTP_PORT" \
  valid_port "HTTP_PORT must be a number between 1 and 65535"
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
ask PUBLIC_SERVER "🌐 Public server address" "$DEFAULT_PUBLIC_SERVER" \
  valid_url "PUBLIC_SERVER must be a full URL starting with http:// or https://"
PUBLIC_SERVER=$(trim_url "$PUBLIC_SERVER")
PUBLIC_HOST=$(url_host "$PUBLIC_SERVER")
[[ -n "$PUBLIC_HOST" ]] \
  || fatal "Could not derive a hostname from PUBLIC_SERVER=${PUBLIC_SERVER}"

if [[ -z "$PORTAL_DIR" ]] && [[ -f "${DEFAULT_PORTAL_DIR}/.env" ]]; then
  PORTAL_DIR="$DEFAULT_PORTAL_DIR"
fi

if [[ -z "$PORTAL_SERVER" ]]; then
  # Prefer the portal checkout next to this repository. Using its .env avoids
  # copying PUBLIC_SERVER by hand and keeps the two values identical.
  if [[ -n "$PORTAL_DIR" ]]; then
    PORTAL_SERVER=$(portal_public_server_from_dir "$PORTAL_DIR" || true)
    [[ -n "$PORTAL_SERVER" ]] \
      || fatal "Could not read PUBLIC_SERVER from ${PORTAL_DIR}/.env; pass --portal-server URL"
    >&2 echo "🔗 Using portal URL from ${PORTAL_DIR}/.env"
  elif [[ "$LOCAL" == true ]]; then
    PORTAL_SERVER="http://localhost:9080"
  elif [[ "$YES" == true ]]; then
    portal_hint=""
    [[ "${EMOBASE_CLI:-}" == "1" ]] && portal_hint=", or run 'emobase create portal' first"
    fatal "PORTAL_SERVER is required; pass --portal-server URL (or --portal-dir DIR)${portal_hint}"
  else
    if [[ ! -t 0 ]]; then
      fatal "Cannot ask for the portal origin: stdin is not a terminal. Pass --portal-server URL or --portal-dir DIR."
    fi
    >&2 echo "No local portal checkout was found."
    >&2 echo "Enter the public URL of the portal on the other server."
    if [[ "${EMOBASE_CLI:-}" == "1" ]]; then
      >&2 echo "If this server should host the portal, run 'emobase create portal' first."
    fi
    PORTAL_SERVER="$(read_value "🌐 Portal origin serving genomics/JBrowse2/BLAST" "" \
      valid_url "PORTAL_SERVER must be a full URL starting with http:// or https://")"
  fi
fi
while [[ "$PORTAL_SERVER" == */ ]]; do
  PORTAL_SERVER="${PORTAL_SERVER%/}"
done
[[ "$PORTAL_SERVER" =~ ^https?://[^/]+ ]] \
  || fatal "PORTAL_SERVER must be a full URL starting with http:// or https://"

# PORTAL_INTERNAL_URL is derived, never asked:
#   - portal on this Docker host: http://host.docker.internal:<portal port>,
#     using HTTP_PORT from the portal .env when the checkout is known;
#   - remote portal: leave it empty so compose falls back to PORTAL_SERVER.
# --portal-internal-url still overrides the derived value.
if [[ -n "$PORTAL_INTERNAL_URL" ]]; then
  PORTAL_INTERNAL_URL="${PORTAL_INTERNAL_URL%/}"
elif [[ -n "$PORTAL_DIR" || "$LOCAL" == true ]]; then
  portal_http_port=""
  if [[ -n "$PORTAL_DIR" ]]; then
    portal_http_port=$(read_env_value "$PORTAL_DIR/.env" HTTP_PORT || true)
  fi
  [[ -n "$portal_http_port" ]] || portal_http_port=$(url_port "$PORTAL_SERVER")
  PORTAL_INTERNAL_URL="http://host.docker.internal:${portal_http_port}"
fi

if [[ ( -n "$PORTAL_DIR" || "$LOCAL" == true ) ]] \
  && [[ "$PORTAL_INTERNAL_URL" == "$PORTAL_SERVER" ]]; then
  >&2 echo "⚠️  PORTAL_INTERNAL_URL is the public portal URL while the portal is local."
  >&2 echo "   Containers may not resolve it. Use http://host.docker.internal:${portal_http_port}."
fi

ask DIRECTUS_DB_DATABASE "🗄️  Directus database" "directus_${species_slug}" \
  valid_database "DIRECTUS_DB_DATABASE may only contain letters, digits and underscores"

ask CONTAINER_PREFIX "📦 Compose project/container prefix" "$species_slug" \
  valid_container_prefix "CONTAINER_PREFIX may only contain letters, digits, dot, underscore and hyphen"

# Elasticsearch is shared with the portal and every species. Each stack owns
# only indices under this prefix. ES index names are lowercase; "genomics" is
# reserved for the portal.
ask EMOBASE_ES_INDEX_PREFIX "🔎 Elasticsearch index prefix" "$species_slug" \
  valid_es_prefix "EMOBASE_ES_INDEX_PREFIX may only contain lowercase letters, digits, underscore and hyphen, must start with a letter or digit, and cannot be 'genomics'"

# ── Keycloak credentials ───────────────────────────────────────────────────
# The realm, client and seed user are created on the portal host (or in the
# Keycloak web UI) before this script runs. This stack only consumes them.
ask KEYCLOAK_REALM "🔐 Keycloak realm" "" \
  valid_keycloak_name "Keycloak realm names may only contain letters, digits, dot, underscore and hyphen."
[[ -n "$KEYCLOAK_REALM" ]] \
  || fatal "KEYCLOAK_REALM is required; create the realm on the portal host first."
ask KEYCLOAK_CLIENT_ID "🔑 Keycloak client ID" "" \
  valid_keycloak_name "Keycloak client IDs may only contain letters, digits, dot, underscore and hyphen."
[[ -n "$KEYCLOAK_CLIENT_ID" ]] \
  || fatal "KEYCLOAK_CLIENT_ID is required; copy it from the portal."
[[ -n "$KEYCLOAK_CLIENT_SECRET" ]] \
  || fatal "KEYCLOAK_CLIENT_SECRET is required; copy it from the portal's create-realm output."
COCO_USERNAME="${COCO_USERNAME:-coco}"
[[ -n "$COCO_PASSWORD" ]] \
  || fatal "COCO_PASSWORD is required; copy it from the portal's create-realm output."

[[ "$KEYCLOAK_REALM" =~ ^[a-zA-Z0-9_.-]+$ ]] \
  || fatal "Keycloak realm names may only contain letters, digits, dot, underscore and hyphen."
[[ "$KEYCLOAK_CLIENT_ID" =~ ^[a-zA-Z0-9_.-]+$ ]] \
  || fatal "Keycloak client IDs may only contain letters, digits, dot, underscore and hyphen."

if [[ -z "$KEYCLOAK_PUBLIC_URL" ]]; then
  if [[ -n "$PORTAL_DIR" ]] && [[ -f "$PORTAL_DIR/.env" ]]; then
    KEYCLOAK_PUBLIC_URL=$(read_env_value "$PORTAL_DIR/.env" KEYCLOAK_PUBLIC_URL || true)
  fi
  KEYCLOAK_PUBLIC_URL="${KEYCLOAK_PUBLIC_URL:-${PORTAL_SERVER%/}/keycloak}"
fi
[[ -n "$KEYCLOAK_PUBLIC_URL" ]] \
  || fatal "KEYCLOAK_PUBLIC_URL is required; pass --keycloak-public-url or set PORTAL_SERVER."
KEYCLOAK_PUBLIC_URL="${KEYCLOAK_PUBLIC_URL%/}"
KEYCLOAK_INTERNAL_URL="${KEYCLOAK_INTERNAL_URL%/}"
if [[ -z "$DIRECTUS_DB_DATABASE" ]]; then
  DIRECTUS_DB_DATABASE="directus_${species_slug}"
fi
[[ "$DIRECTUS_DB_DATABASE" =~ ^[A-Za-z0-9_]+$ ]] \
  || fatal "DIRECTUS_DB_DATABASE may only contain letters, digits and underscores"

# Values for the shared species .env renderer (lib/species-env.sh).
EMOBASE_WEB_IMAGE=ghcr.io/emobase/emobase-web:dev
EMOBASE_INFRA_NETWORK="$INFRA_NETWORK"
COMPOSE_PROJECT_NAME="$CONTAINER_PREFIX"
COMPOSE_FILE="$COMPOSE_FILES"
PUBLIC_DATA_DIR=./data/public
PRIVATE_DATA_DIR=./data/private
IMAGE_DIR=./images
SPECIES_UID=$(id -u)
SPECIES_GID=$(id -g)
SSR_OIDC_SESSION_SECRET=$(generate_secret_key 48)
DIRECTUS_SECRET=$(generate_secret_key 32)
DIRECTUS_ADMIN_EMAIL=admin@emobase.org
DIRECTUS_ADMIN_PASSWORD=$(generate_password)
unset OBA_IMAGE

if [[ "$PRINT" == true ]]; then
  render_species_env
else
  tmp_env=$(mktemp)
  if ! render_species_env > "$tmp_env"; then
    rm -f "$tmp_env"
    fatal "could not render .env; the missing values are listed above"
  fi
  mv "$tmp_env" .env
  chmod 600 .env
  >&2 echo "✅ .env file generated successfully"
  >&2 echo "   Species URL:  ${PUBLIC_SERVER}"
  >&2 echo "   Portal URL:   ${PORTAL_SERVER}"
  if [[ -n "$PORTAL_INTERNAL_URL" ]]; then
    >&2 echo "   Internal URL: ${PORTAL_INTERNAL_URL}"
  else
    >&2 echo "   Internal URL: (compose default: ${PORTAL_SERVER})"
  fi
  >&2 echo "   Directus DB:  ${DIRECTUS_DB_DATABASE}"
  >&2 echo "   ES prefix:    ${EMOBASE_ES_INDEX_PREFIX}"
  >&2 echo "   Keycloak URL: ${KEYCLOAK_PUBLIC_URL}"
  >&2 echo "   Keycloak realm: ${KEYCLOAK_REALM}"
  # When init.sh runs through the CLI, the CLI prints the next step
  # (emobase species setup or emobase bootstrap). Keep the manual steps for
  # standalone runs so the two do not both say "Next:".
  if [[ "${EMOBASE_CLI:-}" != "1" ]]; then
    >&2 echo
    >&2 echo "Next:"
    >&2 echo "  1. Make sure emobase-infra is running."
    >&2 echo "  2. Create this species' Directus database:"
    >&2 echo "       ${INFRA_DIR}/scripts/create-database.sh ${DIRECTUS_DB_DATABASE}"
    >&2 echo "  3. docker compose run --rm setup-directus"
    >&2 echo "  4. ${COMPOSE_CMD} up -d --wait"
  fi
fi
