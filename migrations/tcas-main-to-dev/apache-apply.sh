#!/usr/bin/env bash
#
# Install or restore the final *:443 vhost for the Tcas migration.
# Run it as root: sudo ./apache-apply.sh
#
# It finds the vhost that currently serves 443, keeps the first copy as
# <file>.bak, installs the generated block, tests the configuration and only
# then reloads Apache. A failing configtest restores the backup.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${MIGRATION_CONFIG:-$SCRIPT_DIR/migration.env}"
FINAL=
TARGET=
RESTORE=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: sudo ./apache-apply.sh [options]

Install <NEW_WORKSPACE>/apache-final.conf as the active *:443 vhost:

  1. find the vhost with `apachectl -S`
  2. save its first copy as <file>.bak
  3. install the generated block
  4. run `apachectl configtest`; on failure restore the backup
  5. `systemctl reload apache2`

Options:
  --final FILE   vhost to install (default: apache-final.conf in NEW_WORKSPACE)
  --file FILE    *:443 vhost to replace (default: detected with apachectl -S)
  --restore      copy <file>.bak back and reload Apache
  --dry-run      print the plan; needs no root and changes nothing
  -h, --help     show this help
EOF
}

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --final) FINAL=$2; shift 2 ;;
    --file) TARGET=$2; shift 2 ;;
    --restore) RESTORE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

resolve() {
  local path=$1 resolved
  resolved=$(readlink -f "$path" 2>/dev/null || true)
  printf '%s\n' "${resolved:-$path}"
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

if [[ -z "$TARGET" ]]; then
  TARGET=$(detect_target)
fi
TARGET=$(resolve "$TARGET")

if (( RESTORE )); then
  BACKUP="$TARGET.bak"
  [[ -f "$BACKUP" ]] || die "no backup at $BACKUP"
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

if [[ -z "$FINAL" ]]; then
  [[ -f "$CONFIG" ]] \
    || die "$CONFIG not found; pass --final FILE"
  # Read the one value instead of sourcing a user-owned file as root.
  NEW_WORKSPACE=$(grep -E '^NEW_WORKSPACE=' "$CONFIG" | tail -n1 | cut -d= -f2-)
  [[ -n "$NEW_WORKSPACE" ]] \
    || die "$CONFIG has no NEW_WORKSPACE; pass --final FILE"
  FINAL="$NEW_WORKSPACE/apache-final.conf"
fi

[[ -f "$FINAL" ]] \
  || die "$FINAL not found; run ./migrate.sh apache first"
grep -q '<VirtualHost \*:443>' "$FINAL" \
  || die "$FINAL has no <VirtualHost *:443> block"
[[ -f "$TARGET" ]] || die "vhost not found: $TARGET"

BACKUP="$TARGET.bak"

if (( DRY_RUN )); then
  log "vhost:  $TARGET"
  log "final:  $FINAL"
  log "backup: $BACKUP"
  printf '\nWould run:\n  install -m 0644 %q %q\n  apachectl configtest\n  systemctl reload apache2\n' \
    "$FINAL" "$TARGET"
  exit 0
fi

(( EUID == 0 )) || die "this script edits Apache configuration; run it with sudo"

if [[ -f "$BACKUP" ]]; then
  log "keeping existing backup: $BACKUP"
else
  cp -p "$TARGET" "$BACKUP"
  log "backup: $BACKUP"
fi

install -m 0644 "$FINAL" "$TARGET"
log "installed $FINAL"

if ! apachectl configtest; then
  warn "configtest failed; restoring $BACKUP"
  cp -p "$BACKUP" "$TARGET"
  die "Apache configuration restored; nothing was reloaded"
fi

systemctl reload apache2
log "reloaded Apache"
