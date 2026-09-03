#!/usr/bin/env bash

# Activate a verified JinVault release on the production host. This file is
# installed root-owned on VP and is invoked by the self-hosted Actions runner
# through a narrowly scoped sudo rule. It never reads the database, admin
# token, or SMTP password.

set -Eeuo pipefail
IFS=$'\n\t'

[[ "${EUID}" -eq 0 ]] || { echo 'This script must run as root.' >&2; exit 1; }
[[ $# -eq 3 ]] || { echo "Usage: $0 ARCHIVE CHECKSUMS RELEASE" >&2; exit 2; }

ARCHIVE="$1"
CHECKSUMS="$2"
RELEASE="$3"
APP_DIR=/opt/jinvault
DATA_DIR=/var/lib/jinvault
SERVICE=jinvault.service

[[ "$RELEASE" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'Invalid release identifier.' >&2; exit 2; }

command -v sha256sum >/dev/null || { echo 'sha256sum is required.' >&2; exit 1; }
command -v tar >/dev/null || { echo 'tar is required.' >&2; exit 1; }
command -v curl >/dev/null || { echo 'curl is required for the health check.' >&2; exit 1; }
[[ -r "$ARCHIVE" ]] || { echo "Cannot read archive: $ARCHIVE" >&2; exit 1; }
[[ -r "$CHECKSUMS" ]] || { echo "Cannot read checksums: $CHECKSUMS" >&2; exit 1; }

CHECKSUM_DIR="$(dirname -- "$CHECKSUMS")"
CHECKSUM_NAME="$(basename -- "$CHECKSUMS")"
(cd "$CHECKSUM_DIR" && sha256sum -c "$CHECKSUM_NAME")

test -x "$APP_DIR/jinvault" || { echo "Missing $APP_DIR/jinvault; complete the one-time setup first." >&2; exit 1; }
test -d "$APP_DIR/web-vault" || { echo "Missing $APP_DIR/web-vault; complete the one-time setup first." >&2; exit 1; }
test -d "$DATA_DIR" || { echo "Missing $DATA_DIR; complete the one-time setup first." >&2; exit 1; }
systemctl cat "$SERVICE" >/dev/null || { echo "Missing $SERVICE; complete the one-time setup first." >&2; exit 1; }
for credential in database-url admin-token; do
  test -s "/etc/jinvault/credentials/$credential" || {
    echo "Missing /etc/jinvault/credentials/$credential" >&2
    exit 1
  }
done

RELEASE_DIR="$APP_DIR/releases/$RELEASE"
install -d -o root -g jinvault -m 0750 "$RELEASE_DIR/web-vault"
tar -xzf "$ARCHIVE" -C "$RELEASE_DIR"
install -o root -g root -m 0755 "$RELEASE_DIR/jinvault" "$RELEASE_DIR/jinvault.new"
rm -f "$RELEASE_DIR/jinvault"
mv "$RELEASE_DIR/jinvault.new" "$RELEASE_DIR/jinvault"
chown -R root:jinvault "$RELEASE_DIR/web-vault"
find "$RELEASE_DIR/web-vault" -type d -exec chmod 0750 {} +
find "$RELEASE_DIR/web-vault" -type f -exec chmod 0640 {} +

PREVIOUS_BINARY="$APP_DIR/jinvault.prev.$RELEASE"
PREVIOUS_WEB_VAULT="$APP_DIR/web-vault.prev.$RELEASE"
mv "$APP_DIR/jinvault" "$PREVIOUS_BINARY"
mv "$APP_DIR/web-vault" "$PREVIOUS_WEB_VAULT"
mv "$RELEASE_DIR/jinvault" "$APP_DIR/jinvault"
mv "$RELEASE_DIR/web-vault" "$APP_DIR/web-vault"
rmdir "$RELEASE_DIR" 2>/dev/null || true

rollback() {
  echo 'Restoring the previous application files.' >&2
  systemctl stop "$SERVICE" >/dev/null 2>&1 || true
  rm -f "$APP_DIR/jinvault"
  rm -rf "$APP_DIR/web-vault"
  mv "$PREVIOUS_BINARY" "$APP_DIR/jinvault"
  mv "$PREVIOUS_WEB_VAULT" "$APP_DIR/web-vault"
  systemctl start "$SERVICE" >/dev/null 2>&1 || true
}

if ! systemctl restart "$SERVICE"; then
  rollback
  exit 1
fi
sleep 2
if ! systemctl is-active --quiet "$SERVICE"; then
  systemctl --no-pager --full status "$SERVICE" || true
  journalctl -u "$SERVICE" -n 60 --no-pager || true
  rollback
  exit 1
fi
if ! curl --fail --silent --show-error http://127.0.0.1:8000/alive >/dev/null; then
  rollback
  exit 1
fi

echo "JinVault release $RELEASE is active."
