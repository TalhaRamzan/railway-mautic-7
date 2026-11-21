#!/bin/bash
# Syncs Mautic's config/local.php between services through the MariaDB database.
#
# Why: a Railway volume can only be attached to one service. The web service owns the
# volume (and local.php, which Mautic rewrites whenever an admin saves Configuration).
# The cron and worker services need the same file (secret key, email settings, ...),
# so web pushes it into a one-row table and cron/worker pull it.
#
# Usage:
#   mautic-config-sync push        upload local.php if it changed (web)
#   mautic-config-sync push-loop   push every CONFIG_SYNC_INTERVAL seconds (web, background)
#   mautic-config-sync pull        download local.php if the remote copy changed (cron/worker)
#   mautic-config-sync pull-loop   pull every CONFIG_SYNC_INTERVAL seconds (worker)
#   mautic-config-sync exists      exit 0 if a remote copy exists
#
# Exit codes: 0 ok / nothing to do, 1 error, 3 no remote copy yet.

set -uo pipefail

CONFIG_DIR="${MAUTIC_VOLUME_CONFIG:-/var/www/html/config}"
LOCAL_PHP="${CONFIG_DIR}/local.php"
TABLE="railway_config_sync"
KEY="local.php"
INTERVAL="${CONFIG_SYNC_INTERVAL:-30}"

log() { echo "[config-sync] $*"; }
err() { echo "[config-sync] ERROR: $*" >&2; }

for v in MAUTIC_DB_HOST MAUTIC_DB_USER MAUTIC_DB_PASSWORD MAUTIC_DB_DATABASE; do
  if [ -z "${!v:-}" ]; then
    err "${v} is not set"
    exit 1
  fi
done

if command -v mariadb >/dev/null 2>&1; then MYSQL_BIN=mariadb; else MYSQL_BIN=mysql; fi

# Password goes through the environment, never the command line.
sql() {
  MYSQL_PWD="${MAUTIC_DB_PASSWORD}" "${MYSQL_BIN}" \
    --protocol=TCP \
    --host="${MAUTIC_DB_HOST}" \
    --port="${MAUTIC_DB_PORT:-3306}" \
    --user="${MAUTIC_DB_USER}" \
    --database="${MAUTIC_DB_DATABASE}" \
    --connect-timeout=10 \
    --batch --skip-column-names --raw \
    "$@"
}

ensure_table() {
  sql -e "CREATE TABLE IF NOT EXISTS \`${TABLE}\` (
      \`name\` VARCHAR(64) NOT NULL PRIMARY KEY,
      \`content\` MEDIUMTEXT NOT NULL,
      \`sha256\` CHAR(64) NOT NULL,
      \`updated_at\` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4"
}

remote_sha() {
  # Prints the remote sha256, or nothing if the table/row does not exist.
  sql -e "SELECT \`sha256\` FROM \`${TABLE}\` WHERE \`name\`='${KEY}'" 2>/dev/null || true
}

file_sha() {
  sha256sum "$1" | cut -d' ' -f1
}

is_installed_config() {
  # Same test the upstream image uses: db_driver and site_url must be set.
  php -r "\$parameters = []; include '$1'; exit(!empty(\$parameters['db_driver']) && !empty(\$parameters['site_url']) ? 0 : 1);" >/dev/null 2>&1
}

push() {
  if [ ! -f "${LOCAL_PHP}" ]; then
    err "${LOCAL_PHP} does not exist, nothing to push"
    return 1
  fi
  if ! is_installed_config "${LOCAL_PHP}"; then
    err "${LOCAL_PHP} is not a completed Mautic config (no site_url/db_driver), not pushing"
    return 1
  fi
  local sha b64 current
  sha="$(file_sha "${LOCAL_PHP}")"
  current="$(remote_sha)"
  if [ "${sha}" = "${current}" ]; then
    return 0
  fi
  ensure_table || { err "cannot create table ${TABLE}"; return 1; }
  b64="$(base64 -w0 "${LOCAL_PHP}")"
  # The payload is base64 (A-Z a-z 0-9 + / =), so it is safe inside single quotes.
  if printf "INSERT INTO \`%s\` (\`name\`, \`content\`, \`sha256\`) VALUES ('%s', FROM_BASE64('%s'), '%s') ON DUPLICATE KEY UPDATE \`content\`=VALUES(\`content\`), \`sha256\`=VALUES(\`sha256\`);\n" \
      "${TABLE}" "${KEY}" "${b64}" "${sha}" | sql; then
    log "pushed local.php (${sha:0:12})"
  else
    err "push failed"
    return 1
  fi
}

pull() {
  local current local_sha tmp
  current="$(remote_sha)"
  if [ -z "${current}" ]; then
    return 3
  fi
  if [ -f "${LOCAL_PHP}" ]; then
    local_sha="$(file_sha "${LOCAL_PHP}")"
    if [ "${local_sha}" = "${current}" ]; then
      return 0
    fi
  fi
  tmp="$(mktemp "${CONFIG_DIR}/.local.php.XXXXXX")" || { err "cannot create temp file in ${CONFIG_DIR}"; return 1; }
  if ! sql -e "SELECT REPLACE(TO_BASE64(\`content\`), CHAR(10), '') FROM \`${TABLE}\` WHERE \`name\`='${KEY}'" | base64 -d > "${tmp}"; then
    rm -f "${tmp}"
    err "download failed"
    return 1
  fi
  if [ "$(file_sha "${tmp}")" != "${current}" ]; then
    rm -f "${tmp}"
    err "checksum mismatch, keeping the current local.php"
    return 1
  fi
  if ! php -l "${tmp}" >/dev/null 2>&1 || ! is_installed_config "${tmp}"; then
    rm -f "${tmp}"
    err "remote local.php is not valid PHP or not a completed config, ignoring it"
    return 1
  fi
  chmod 0640 "${tmp}"
  if [ "$(id -u)" = "0" ]; then chown www-data:www-data "${tmp}"; fi
  mv -f "${tmp}" "${LOCAL_PHP}"
  log "pulled local.php (${current:0:12})"
}

case "${1:-}" in
  push)
    push
    ;;
  push-loop)
    while true; do
      push || true
      sleep "${INTERVAL}"
    done
    ;;
  pull)
    pull
    rc=$?
    # "no remote copy yet" is not an error for the periodic cron job
    [ "${rc}" = "3" ] && exit 0
    exit "${rc}"
    ;;
  pull-loop)
    while true; do
      pull || true
      sleep "${INTERVAL}"
    done
    ;;
  exists)
    [ -n "$(remote_sha)" ] && exit 0
    exit 3
    ;;
  *)
    echo "usage: $0 push|push-loop|pull|pull-loop|exists" >&2
    exit 2
    ;;
esac
