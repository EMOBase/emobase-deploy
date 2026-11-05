#!/usr/bin/env bash

set -eo pipefail

PASSWORD_LENGTH=16
FORCE=false
YES=false
LOCAL=false
MAIN_SPECIES=
PUBLIC_SERVER=
PORTAL_SERVER=
PORTAL_DIR=
HTTP_PORT=
COCO_USERNAME=
CONTAINER_PREFIX=

DEFAULT_COCO_USERNAME=coco
DEFAULT_HTTP_PORT=9090
DEFAULT_PUBLIC_SERVER="http://localhost:${DEFAULT_HTTP_PORT}"
DEFAULT_PORTAL_DIR="../emobase-portal-deploy"

fatal() {
  >&2 echo "❌ $1"
  exit 1
}

generate_secret_key() {
  length="${1:-32}"
  local key # Needed to avoid pipefail
  key=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$length")
  echo "$key"
}

generate_password() {
  length="${1:-$PASSWORD_LENGTH}"

  upper=$(LC_ALL=C tr -dc 'A-Z' </dev/urandom | head -c1)
  lower=$(LC_ALL=C tr -dc 'a-z' </dev/urandom | head -c1)
  digit=$(LC_ALL=C tr -dc '0-9' </dev/urandom | head -c1)
  symbol=$(LC_ALL=C tr -dc '_+=-' </dev/urandom | head -c1)

  rest_length=$((length - 4))
  rest=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$rest_length")

  # Shuffle safely using awk (portable)
  printf "%s\n" "$upper$lower$digit$symbol$rest" | \
    awk 'BEGIN{srand()} {for(i=1;i<=length;i++) a[i]=substr($0,i,1)}
         END{for(i=1;i<=length;i++){j=int(rand()*length)+1; tmp=a[i]; a[i]=a[j]; a[j]=tmp}
             for(i=1;i<=length;i++) printf a[i]; printf "\n"}'
}

# Best-effort non-loopback IPv4 used by --local. The address has to be
# reachable from inside Docker as well, so 127.0.0.1/localhost is not enough.
detect_local_ip() {
  local ip=""

  if command -v ipconfig >/dev/null 2>&1; then
    ip=$(ipconfig getifaddr en0 2>/dev/null || true)
    [[ -n "$ip" ]] || ip=$(ipconfig getifaddr en1 2>/dev/null || true)
  fi

  if [[ -z "$ip" ]] && command -v ip >/dev/null 2>&1; then
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  fi

  if [[ -z "$ip" ]] && command -v hostname >/dev/null 2>&1; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi

  [[ -n "$ip" ]] || return 1
  [[ "$ip" == 127.* ]] && return 1
  echo "$ip"
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
    --portal-dir)
      PORTAL_DIR="$2"
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
      echo "Usage: $0 [-f|--force] [-p|--print] [-y|--yes] [--local] [-s|--species SPECIES] [--public-server URL] [--http-port PORT] [--portal-server URL] [--portal-dir DIR] [--container-prefix PREFIX]"
      echo "  -s, --species       4-letter species code (e.g. Tcas, Dmel, Ptep)"
      echo "  --public-server     Public server address (default: http://localhost:<http-port>)"
      echo "  --http-port         Host port for nginx (default: ${DEFAULT_HTTP_PORT})"
      echo "  --portal-server     Portal origin serving genomics, JBrowse2 and BLAST"
      echo "  --portal-dir        Portal checkout whose .env holds PUBLIC_SERVER"
      echo "                      (default: ${DEFAULT_PORTAL_DIR} when present)"
      echo "  --container-prefix  Prefix for docker compose containers (default: current directory)"
      echo "  --local             Use the machine's LAN IP for PUBLIC_SERVER (local trial)"
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

# Ask for inputs
if [[ -z "$MAIN_SPECIES" ]]; then
  if [[ "$YES" == true ]]; then
    fatal "MAIN_SPECIES is required; pass --species SPECIES"
  fi
  read -rp "🧬 Enter 4-letter species code: " MAIN_SPECIES
  [[ -z "$MAIN_SPECIES" ]] && fatal "MAIN_SPECIES cannot be empty"
fi

if [[ -z "$HTTP_PORT" ]]; then
  HTTP_PORT=${DEFAULT_HTTP_PORT}
fi
[[ "$HTTP_PORT" =~ ^[0-9]+$ ]] && (( 10#$HTTP_PORT >= 1 && 10#$HTTP_PORT <= 65535 )) \
  || fatal "HTTP_PORT must be a number between 1 and 65535"
DEFAULT_PUBLIC_SERVER="http://localhost:${HTTP_PORT}"

if [[ "$LOCAL" == true ]] && [[ -z "$PUBLIC_SERVER" ]]; then
  local_ip=$(detect_local_ip) || fatal "Could not detect a LAN IP; pass --public-server URL"
  PUBLIC_SERVER="http://${local_ip}:${HTTP_PORT}"
  >&2 echo "🏠 Local mode: using ${PUBLIC_SERVER}"
fi

if [[ -z "$PUBLIC_SERVER" ]]; then
  if [[ "$YES" == true ]]; then
    PUBLIC_SERVER=${DEFAULT_PUBLIC_SERVER}
  else
    read -rp "🌐 Enter public server address [${DEFAULT_PUBLIC_SERVER}]: " PUBLIC_SERVER
    PUBLIC_SERVER="${PUBLIC_SERVER:-${DEFAULT_PUBLIC_SERVER}}"
  fi
fi
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
  elif [[ "$YES" == true ]]; then
    fatal "PORTAL_SERVER is required; pass --portal-server URL or --portal-dir DIR"
  else
    read -rp "🌐 Enter portal origin serving genomics/JBrowse2/BLAST: " PORTAL_SERVER
  fi
fi
PORTAL_SERVER="${PORTAL_SERVER%/}"
[[ -z "$PORTAL_SERVER" ]] && fatal "PORTAL_SERVER cannot be empty"
if [[ "$PORTAL_SERVER" == *localhost* ]] || [[ "$PORTAL_SERVER" == *127.0.0.1* ]]; then
  >&2 echo "⚠️  PORTAL_SERVER points at localhost. The species nginx container cannot"
  >&2 echo "   reach the portal there; use a LAN IP or DNS name instead."
fi

if [[ -z "$COCO_USERNAME" ]]; then
  if [[ "$YES" == true ]]; then
    COCO_USERNAME=${DEFAULT_COCO_USERNAME}
  else
    read -rp "🌐 Enter Community Coordinator username [${DEFAULT_COCO_USERNAME}]: " COCO_USERNAME
    COCO_USERNAME="${COCO_USERNAME:-${DEFAULT_COCO_USERNAME}}"
  fi
fi

ENV_CONTENT="# 4-letter code of your species (e.g. Tcas, Dmel, Ptep)
MAIN_SPECIES=${MAIN_SPECIES}

# Web UI image
EMOBASE_WEB_IMAGE=ghcr.io/emobase/emobase-web:dev

# The full address to access the app from public, including protocol and port (if not 80 or 443)
PUBLIC_SERVER=${PUBLIC_SERVER}

# Public origin of the portal deployment that serves genomics, JBrowse2 and BLAST
PORTAL_SERVER=${PORTAL_SERVER}

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
SSR_OIDC_SESSION_SECRET=$(generate_secret_key 48)
KEYCLOAK_CLIENT_SECRET=$(generate_secret_key 32)
DIRECTUS_SECRET=$(generate_secret_key 32)

# Credentials
MYSQL_ROOT_PASSWORD=$(generate_password)
KEYCLOAK_ADMIN=admin
KEYCLOAK_ADMIN_PASSWORD=$(generate_password)
DIRECTUS_ADMIN_EMAIL=admin@emobase.org
DIRECTUS_ADMIN_PASSWORD=$(generate_password)
COCO_USERNAME=${COCO_USERNAME}
COCO_PASSWORD=$(generate_password)"

if [[ "$PRINT" == true ]]; then
  echo "$ENV_CONTENT"
else
  printf '%s\n' "$ENV_CONTENT" > .env
  chmod 600 .env
  >&2 echo "✅ .env file generated successfully"
  >&2 echo "   Species URL: ${PUBLIC_SERVER}"
  >&2 echo "   Portal URL:  ${PORTAL_SERVER}"
fi
