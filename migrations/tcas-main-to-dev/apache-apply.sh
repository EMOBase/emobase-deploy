#!/usr/bin/env bash
#
# Generate and install the final *:443 vhost for the Tcas migration.
# Run it as root: sudo ./apache-apply.sh
#
# It reads migration.env, detects the certificate, finds the vhost that
# currently serves 443, keeps its first copy as
# <file>.bak, installs the generated block, tests the configuration and only
# then reloads Apache. A failing configtest restores the backup.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${MIGRATION_CONFIG:-$SCRIPT_DIR/migration.env}"
TARGET=
BACKUP_OPT=
RESTORE=0
DRY_RUN=0

TCAS_URL=
TCAS_HOST=
NEW_HTTP_PORT=9092
SSL_CERT_FILE=
SSL_CERT_KEY_FILE=

usage() {
  cat <<'EOF'
Usage: sudo ./apache-apply.sh [options]

Generate the final vhost from migration.env and install it as the active
*:443 vhost:

  1. read migration.env and detect the certificate
  2. find the vhost with `apachectl -S`
  3. save its first copy as <file>.bak
  4. install the generated block
  5. run `apachectl configtest`; on failure restore the backup
  6. `systemctl reload apache2`

Options:
  --config FILE  use FILE instead of migration.env
  --file FILE    *:443 vhost to replace (default: detected with apachectl -S)
  --restore      copy the saved vhost back and reload Apache
  --backup FILE  restore: backup to use (default: the recorded one)
  --dry-run      print the vhost and the plan; needs no root, changes nothing
  -h, --help     show this help
EOF
}

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --config) CONFIG=$2; shift 2 ;;
    --file) TARGET=$2; shift 2 ;;
    --backup) BACKUP_OPT=$2; shift 2 ;;
    --restore) RESTORE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

# Read one value; do not source a user-owned file as root.
cfg() {
  grep -E "^$1=" "$CONFIG" 2>/dev/null | tail -n1 | cut -d= -f2- || true
}

resolve() {
  local path=$1 resolved
  resolved=$(readlink -f "$path" 2>/dev/null || true)
  printf '%s\n' "${resolved:-$path}"
}

STATE_FILE="$(dirname "$CONFIG")/.apache-backup"

recorded_backup() {
  [[ -f "$STATE_FILE" ]] || return 1
  local bak
  bak=$(cat "$STATE_FILE")
  [[ -f "$bak" ]] || return 1
  printf '%s\n' "$bak"
}

# The vhost saved before the first install. An existing <file>.bak may belong
# to another deployment, so it is only reused when it matches the current
# vhost; otherwise the current vhost is copied to a timestamped file.
plan_backup() {
  local bak
  if bak=$(recorded_backup); then
    printf '%s\n' "$bak"
    return 0
  fi
  if [[ -f "$TARGET.bak" ]]; then
    if cmp -s "$TARGET.bak" "$TARGET"; then
      printf '%s\n' "$TARGET.bak"
    else
      printf '%s\n' "$TARGET.bak.$(date +%Y%m%d%H%M%S)"
    fi
  else
    printf '%s\n' "$TARGET.bak"
  fi
}

detect_target() {
  command -v apachectl >/dev/null 2>&1 || die "apachectl not found"
  local out files
  out=$(apachectl -S 2>/dev/null) || die "apachectl -S failed"
  files=$(printf '%s\n' "$out" \
    | grep -E 'port 443|:443' \
    | grep -oE '/[^()]+\.conf:[0-9]+' \
    | sed 's/:[0-9]*$//' \
    | sort -u)
  [[ -n "$files" ]] || die "no *:443 vhost found; pass --file FILE"
  if [[ $(printf '%s\n' "$files" | wc -l) -gt 1 ]]; then
    printf 'ERROR: more than one *:443 vhost found:\n%s\nPass --file FILE.\n' \
      "$files" >&2
    exit 1
  fi
  printf '%s\n' "$files"
}

load_config() {
  [[ -f "$CONFIG" ]] || die "$CONFIG not found; pass --config FILE"
  TCAS_URL=$(cfg TCAS_URL)
  NEW_HTTP_PORT=$(cfg NEW_HTTP_PORT)
  SSL_CERT_FILE=$(cfg SSL_CERT_FILE)
  SSL_CERT_KEY_FILE=$(cfg SSL_CERT_KEY_FILE)
  [[ -n "$TCAS_URL" ]] || die "$CONFIG has no TCAS_URL"
  NEW_HTTP_PORT=${NEW_HTTP_PORT:-9092}
  TCAS_HOST=$(printf '%s' "$TCAS_URL" | sed -E 's#^[A-Za-z]+://([^/:]+).*#\1#')
  [[ -n "$TCAS_HOST" ]] || die "could not parse a host from $TCAS_URL"
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
    warn "certificate not found: $cert"
  elif [[ ! -f "$cert" ]]; then
    warn "certificate is not a file: $cert"
  fi
  if [[ ! -e "$key" ]]; then
    if [[ -n "${SSL_CERT_KEY_FILE:-}" ]]; then
      warn "private key is not visible to this user; using the configured path: $key"
    else
      warn "private key not found: $key"
    fi
  elif [[ ! -f "$key" ]]; then
    warn "private key is not a file: $key"
  fi
  SSL_CERT_FILE=$cert
  SSL_CERT_KEY_FILE=$key
}

render_vhost() {
  cat <<EOF
# Generated by ./apache-apply.sh for $TCAS_HOST.
# Final 443 vhost; 443 is already in ports.conf.
<VirtualHost *:443>
    ServerName $TCAS_HOST

    SSLEngine on
    SSLCertificateFile    $SSL_CERT_FILE
    SSLCertificateKeyFile $SSL_CERT_KEY_FILE

    ProxyPreserveHost On
    RequestHeader set X-Forwarded-Proto "https"
    LimitRequestFieldSize 16384

    ProxyPass        /  http://127.0.0.1:$NEW_HTTP_PORT/
    ProxyPassReverse /  http://127.0.0.1:$NEW_HTTP_PORT/
</VirtualHost>
EOF
}

if (( RESTORE )); then
  if [[ -z "$TARGET" ]]; then TARGET=$(detect_target); fi
  TARGET=$(resolve "$TARGET")
  if [[ -n "$BACKUP_OPT" ]]; then
    BACKUP=$(resolve "$BACKUP_OPT")
  elif BACKUP=$(recorded_backup); then
    :
  else
    BACKUP="$TARGET.bak"
  fi
  [[ -f "$BACKUP" ]] \
    || die "no backup recorded in $STATE_FILE; pass --backup FILE"
  if (( DRY_RUN )); then
    log "vhost:  $TARGET"
    log "backup: $BACKUP"
    printf '\nWould run:\n  cp -p %q %q\n  apachectl configtest\n  systemctl reload apache2\n' \
      "$BACKUP" "$TARGET"
    exit 0
  fi
  (( EUID == 0 )) || die "this script edits Apache configuration; run it with sudo"
  cp -p "$BACKUP" "$TARGET"
  log "restored $TARGET from $BACKUP"
  apachectl configtest
  systemctl reload apache2
  log "reloaded Apache"
  exit 0
fi

load_config
detect_cert_pair
VHOST=$(render_vhost)

if [[ -z "$TARGET" ]]; then TARGET=$(detect_target); fi
TARGET=$(resolve "$TARGET")
[[ -f "$TARGET" ]] || die "vhost not found: $TARGET"
BACKUP="$TARGET.bak"

BACKUP=$(plan_backup)
if [[ "$BACKUP" == "$TARGET.bak."* ]]; then
  warn "existing $TARGET.bak belongs to another change; the current vhost will be saved as $BACKUP"
fi

if (( DRY_RUN )); then
  log "vhost:   $TARGET"
  log "backup:  $BACKUP"
  log "cert:    $SSL_CERT_FILE"
  log "key:     $SSL_CERT_KEY_FILE"
  printf '\nGenerated vhost:\n\n%s\n\nWould install it as %s, then run:\n  apachectl configtest\n  systemctl reload apache2\n' \
    "$VHOST" "$TARGET"
  exit 0
fi

(( EUID == 0 )) || die "this script edits Apache configuration; run it with sudo"

if [[ ! -f "$BACKUP" ]]; then
  cp -p "$TARGET" "$BACKUP"
fi
printf '%s\n' "$BACKUP" > "$STATE_FILE"
log "backup: $BACKUP"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
printf '%s\n' "$VHOST" > "$tmp"
chmod 644 "$tmp"
install -m 0644 "$tmp" "$TARGET"
log "installed $TARGET"

if ! apachectl configtest; then
  warn "configtest failed; restoring $BACKUP"
  cp -p "$BACKUP" "$TARGET"
  die "Apache configuration restored; nothing was reloaded"
fi

systemctl reload apache2
log "reloaded Apache"
