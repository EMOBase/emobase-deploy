#!/usr/bin/env bash

set -eo pipefail

PASSWORD_LENGTH=16
FORCE=false
YES=false
MAIN_SPECIES=
PUBLIC_SERVER=
COCO_USERNAME=
CONTAINER_PREFIX=

DEFAULT_COCO_USERNAME=coco
DEFAULT_PUBLIC_SERVER="http://localhost:9090"

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
    *)
      echo "Usage: $0 [-f|--force] [-p|--print] [-y|--yes] [-s|--species SPECIES] [--public-server URL] [--container-prefix PREFIX]"
      echo "  -s, --species       4-letter species code (e.g. Tcas, Dmel, Ptep)"
      echo "  --public-server     Public server address (default: ${DEFAULT_PUBLIC_SERVER})"
      echo "  --container-prefix  Prefix for docker compose containers (default: current directory)"
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
  read -rp "🧬 Enter 4-letter species code: " MAIN_SPECIES
  [[ -z "$MAIN_SPECIES" ]] && fatal "MAIN_SPECIES cannot be empty"
fi

if [[ -z "$PUBLIC_SERVER" ]]; then
  if [[ "$YES" == true ]]; then
    PUBLIC_SERVER=${DEFAULT_PUBLIC_SERVER}
  else
    read -rp "🌐 Enter public server address [${DEFAULT_PUBLIC_SERVER}]: " PUBLIC_SERVER
    PUBLIC_SERVER="${PUBLIC_SERVER:-${DEFAULT_PUBLIC_SERVER}}"
  fi
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

# For SequenceServer
ASSEMBLY_NAME=${MAIN_ASSEMBLY}

# The full address to access the app from public, including protocol and port (if not 80 or 443)
PUBLIC_SERVER=${PUBLIC_SERVER}

# The port to access the app from localhost
HTTP_PORT=9090

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
  echo "$ENV_CONTENT" > .env
  >&2 echo "✅ .env file generated successfully"
fi