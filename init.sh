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
      echo "Usage: $0 [-f|--force] [-p|--print] [-y|--yes] [--local] [-s|--species SPECIES] [--public-server URL] [--http-port PORT] [--portal-server URL] [--portal-internal-url URL] [--portal-dir DIR] [--container-prefix PREFIX]"
      echo "  -s, --species       4-letter species code (e.g. Tcas, Dmel, Ptep)"
      echo "  --public-server     Public server address (default: http://localhost:<http-port>)"
      echo "  --http-port         Host port for nginx (default: ${DEFAULT_HTTP_PORT})"
      echo "  --portal-server     Public portal origin used by browsers (genomics, JBrowse2, BLAST)"
      echo "  --portal-internal-url"
      echo "                      Portal origin used from inside containers (BLAST proxy, SSR)"
      echo "  --portal-dir        Portal checkout whose .env holds PUBLIC_SERVER"
      echo "                      (default: ${DEFAULT_PORTAL_DIR} when present)"
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
  PUBLIC_SERVER="http://localhost:${HTTP_PORT}"
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
  elif [[ "$YES" == true ]] && [[ "$LOCAL" == true ]]; then
    PORTAL_SERVER="http://localhost:9080"
  elif [[ "$YES" == true ]]; then
    fatal "PORTAL_SERVER is required; pass --portal-server URL or --portal-dir DIR"
  else
    read -rp "🌐 Enter portal origin serving genomics/JBrowse2/BLAST: " PORTAL_SERVER
  fi
fi
PORTAL_SERVER="${PORTAL_SERVER%/}"
[[ -z "$PORTAL_SERVER" ]] && fatal "PORTAL_SERVER cannot be empty"

if [[ -z "$PORTAL_INTERNAL_URL" ]]; then
  if [[ "$LOCAL" == true ]]; then
    PORTAL_INTERNAL_URL="http://host.docker.internal:$(url_port "$PORTAL_SERVER")"
  else
    PORTAL_INTERNAL_URL="$PORTAL_SERVER"
  fi
fi
PORTAL_INTERNAL_URL="${PORTAL_INTERNAL_URL%/}"
[[ -z "$PORTAL_INTERNAL_URL" ]] && fatal "PORTAL_INTERNAL_URL cannot be empty"

if [[ "$PORTAL_SERVER" == *localhost* || "$PORTAL_SERVER" == *127.0.0.1* ]] \
  && [[ "$PORTAL_INTERNAL_URL" == "$PORTAL_SERVER" ]]; then
  >&2 echo "⚠️  PORTAL_SERVER points at localhost and PORTAL_INTERNAL_URL is the same."
  >&2 echo "   Containers cannot reach the portal there. Use --local, or set"
  >&2 echo "   --portal-internal-url to an address reachable from inside Docker."
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

# Portal origin used from inside this stack's containers (BLAST proxy, SSR API
# calls). Use an internal hostname/URL when the portal is on the same Docker
# host; otherwise this may be the same as PORTAL_SERVER.
PORTAL_INTERNAL_URL=${PORTAL_INTERNAL_URL}

# Internal service URLs used for server-side calls. These must be absolute.
# They fall back to the matching PUBLIC_* URL if omitted.
INTERNAL_API_GENOMICS_SERVICE=${PORTAL_INTERNAL_URL}/ibb/api/genomicsservice/v1
INTERNAL_API_PHENOTYPE_SERVICE=http://phenotypeservice:8080
INTERNAL_API_IMAGE_SERVICE=http://imageservice:8080
INTERNAL_API_ONTOLOGY_SERVICE=http://ontologyservice:8080
INTERNAL_API_GO_ANNOTATION_SERVICE=http://goannotationservice:8080
INTERNAL_API_PUBLICATION_SERVICE=http://publicationservice:8080
INTERNAL_API_QUERY_PIPELINE_SERVICE=http://querypipelineservice:8080
INTERNAL_KEYCLOAK_ISSUER=http://keycloak:8080/ibb/keycloak/realms/ibb
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
  >&2 echo "   Internal URL: ${PORTAL_INTERNAL_URL}"
fi
