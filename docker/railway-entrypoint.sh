#!/bin/bash
# Railway wrapper around the official Mautic entrypoint (/entrypoint.sh).
#
# Same image, three roles (DOCKER_MAUTIC_ROLE):
#   mautic_web     public web UI. Owns the volume. Installs Mautic headlessly on first boot,
#                  then pushes config/local.php into the database for the other roles.
#   mautic_cron    runs the cron schedule (docker/mautic.crontab).
#   mautic_worker  consumes the email/hit queues (docker/supervisord-worker.conf).
#
# After preparing config it hands over to the upstream /entrypoint.sh, which checks the
# environment and database, runs migrations (web only) and starts apache/cron/supervisord.

set -euo pipefail

log() { echo "[railway] $*"; }
die() { echo "[railway] ERROR: $*" >&2; exit 1; }

ROLE="${DOCKER_MAUTIC_ROLE:-mautic_web}"
APP_DIR="/var/www/html"
CONFIG_DIR="${MAUTIC_VOLUME_CONFIG:-${APP_DIR}/config}"
CONSOLE="${APP_DIR}/bin/console"
WWW_USER="${MAUTIC_WWW_USER:-www-data}"
DATA_DIR="${DATA_DIR:-${RAILWAY_VOLUME_MOUNT_PATH:-}}"
export MAUTIC_DB_PORT="${MAUTIC_DB_PORT:-3306}"

case "${ROLE}" in
  mautic_web|mautic_cron|mautic_worker) ;;
  *) die "DOCKER_MAUTIC_ROLE must be mautic_web, mautic_cron or mautic_worker (got '${ROLE}')" ;;
esac

for v in MAUTIC_DB_HOST MAUTIC_DB_USER MAUTIC_DB_PASSWORD MAUTIC_DB_DATABASE SITE_URL; do
  [ -n "${!v:-}" ] || die "${v} is not set. See railway-template.md for the variables of the ${ROLE} service."
done

if [ "${DOCKER_MAUTIC_LOAD_TEST_DATA:-false}" = "true" ]; then
  die "DOCKER_MAUTIC_LOAD_TEST_DATA=true would overwrite the admin account with demo data. Not supported by this template."
fi

# ---------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------
if command -v mariadb >/dev/null 2>&1; then MYSQL_BIN=mariadb; else MYSQL_BIN=mysql; fi

sql() {
  MYSQL_PWD="${MAUTIC_DB_PASSWORD}" "${MYSQL_BIN}" --protocol=TCP \
    --host="${MAUTIC_DB_HOST}" --port="${MAUTIC_DB_PORT}" --user="${MAUTIC_DB_USER}" \
    --database="${MAUTIC_DB_DATABASE}" --connect-timeout=10 --batch --skip-column-names "$@"
}

wait_for_db() {
  local i=0
  until MYSQL_PWD="${MAUTIC_DB_PASSWORD}" mysqladmin --protocol=TCP --host="${MAUTIC_DB_HOST}" \
        --port="${MAUTIC_DB_PORT}" --user="${MAUTIC_DB_USER}" --connect-timeout=5 ping >/dev/null 2>&1; do
    i=$((i + 1))
    [ "${i}" -ge 60 ] && die "database ${MAUTIC_DB_HOST}:${MAUTIC_DB_PORT} not reachable after ~5 minutes"
    [ $((i % 6)) -eq 1 ] && log "waiting for database ${MAUTIC_DB_HOST}:${MAUTIC_DB_PORT} ..."
    sleep 5
  done
  log "database is reachable"
}

as_www() {
  runuser -u "${WWW_USER}" -- "$@"
}

config_installed() {
  [ -f "${CONFIG_DIR}/local.php" ] && php -r "\$parameters = []; include '${CONFIG_DIR}/local.php'; exit(!empty(\$parameters['db_driver']) && !empty(\$parameters['site_url']) ? 0 : 1);" >/dev/null 2>&1
}

db_has_mautic_users() {
  local n
  n="$(sql -e "SELECT COUNT(*) FROM \`users\`" 2>/dev/null || true)"
  [ -n "${n}" ] && [ "${n}" != "0" ]
}

write_parameters_local() {
  php /usr/local/lib/railway/write-parameters-local.php "${CONFIG_DIR}/parameters_local.php"
  chown "${WWW_USER}:${WWW_USER}" "${CONFIG_DIR}/parameters_local.php"
}

# Railway does not create the image's VOLUME paths as volumes, so on Railway we point
# config/ and the media upload folders at the single attached volume with symlinks.
# Locally (docker compose) these paths are real mounts and are left alone.
link_to_data_dir() {
  local target="$1" source="$2"
  mkdir -p "${source}"
  if mountpoint -q "${target}" 2>/dev/null; then
    log "${target} is a mount point, using it directly"
    return 0
  fi
  if [ -L "${target}" ]; then
    ln -sfn "${source}" "${target}"
  else
    # First boot on an empty volume: seed it with what the image ships (e.g. .htaccess).
    if [ -d "${target}" ] && [ -z "$(ls -A "${source}")" ]; then
      cp -a "${target}/." "${source}/"
    fi
    rm -rf "${target}"
    ln -s "${source}" "${target}"
  fi
  chown -R "${WWW_USER}:${WWW_USER}" "${source}"
  chown -h "${WWW_USER}:${WWW_USER}" "${target}"
}

setup_web_storage() {
  if [ -z "${DATA_DIR}" ]; then
    if mountpoint -q "${CONFIG_DIR}" 2>/dev/null; then
      log "${CONFIG_DIR} is a mounted volume (docker compose layout)"
      return 0
    fi
    log "WARNING: no volume detected (DATA_DIR / RAILWAY_VOLUME_MOUNT_PATH empty)."
    log "WARNING: config and uploaded media will be LOST on every redeploy. Attach a volume at /data."
    return 0
  fi
  [ -d "${DATA_DIR}" ] || die "DATA_DIR ${DATA_DIR} does not exist"
  log "persistent data directory: ${DATA_DIR}"
  link_to_data_dir "${CONFIG_DIR}" "${DATA_DIR}/config"
  link_to_data_dir "${APP_DIR}/docroot/media/files" "${DATA_DIR}/media/files"
  link_to_data_dir "${APP_DIR}/docroot/media/images" "${DATA_DIR}/media/images"
}

install_mautic() {
  local admin_email="${ADMIN_EMAIL:-}" admin_password="${ADMIN_PASSWORD:-}"
  [ -n "${admin_email}" ] || die "ADMIN_EMAIL is required for the first install"
  [ -n "${admin_password}" ] || die "ADMIN_PASSWORD is required for the first install"
  [ "${#admin_password}" -ge 12 ] || die "ADMIN_PASSWORD must be at least 12 characters"

  log "installing Mautic for ${SITE_URL} (first boot, this takes 1-3 minutes) ..."
  as_www php "${CONSOLE}" mautic:install "${SITE_URL%/}" \
    --force \
    --no-interaction \
    --db_driver=pdo_mysql \
    --db_host="${MAUTIC_DB_HOST}" \
    --db_port="${MAUTIC_DB_PORT}" \
    --db_name="${MAUTIC_DB_DATABASE}" \
    --db_user="${MAUTIC_DB_USER}" \
    --db_password="${MAUTIC_DB_PASSWORD}" \
    --db_backup_tables=false \
    --admin_username="${ADMIN_USERNAME:-admin}" \
    --admin_email="${admin_email}" \
    --admin_password="${admin_password}" \
    --admin_firstname="${ADMIN_FIRSTNAME:-Admin}" \
    --admin_lastname="${ADMIN_LASTNAME:-User}" \
    || die "mautic:install failed (see output above). Fix the cause and redeploy; a partial install is retried."

  config_installed || die "mautic:install finished but ${CONFIG_DIR}/local.php has no site_url"
  log "Mautic installed. Log in at ${SITE_URL%/}/s/login as '${ADMIN_USERNAME:-admin}' (password: ADMIN_PASSWORD variable)."
}

adopt_existing_db() {
  # Volume lost (or DB restored from a dump) and no synced copy in the DB: write a minimal
  # local.php so Mautic starts against the existing data. Encrypted integration secrets
  # created with the old secret key will have to be re-entered.
  log "ADOPT_EXISTING_DB=true: writing a minimal local.php for the existing database"
  local key
  key="$(php -r 'echo hash("sha256", random_bytes(32));')"
  cat > "${CONFIG_DIR}/local.php" <<PHP
<?php
\$parameters = array(
  'db_driver' => 'pdo_mysql',
  'site_url' => '${SITE_URL%/}',
  'secret_key' => '${key}',
);
PHP
  chown "${WWW_USER}:${WWW_USER}" "${CONFIG_DIR}/local.php"
}

# ---------------------------------------------------------------------------------------
# Roles
# ---------------------------------------------------------------------------------------
web() {
  setup_web_storage
  mkdir -p "${CONFIG_DIR}"
  chown "${WWW_USER}:${WWW_USER}" "${CONFIG_DIR}"
  wait_for_db

  if ! config_installed; then
    # Remove an incomplete/template local.php and parameters_local.php so the installer
    # starts clean and Mautic does not think it is already installed.
    rm -f "${CONFIG_DIR}/parameters_local.php"

    if mautic-config-sync exists; then
      log "no local.php on the volume, restoring the copy stored in the database"
      runuser -u "${WWW_USER}" -- mautic-config-sync pull || die "restoring local.php from the database failed"
    elif db_has_mautic_users; then
      if [ "${ADOPT_EXISTING_DB:-false}" = "true" ]; then
        adopt_existing_db
      else
        die "the database already contains Mautic data but there is no local.php. Refusing to reinstall (it would wipe the data). Restore local.php to ${DATA_DIR:-the volume}/config, or set ADOPT_EXISTING_DB=true once. See README.md > Backup & restore."
      fi
    else
      rm -f "${CONFIG_DIR}/local.php"
      install_mautic
    fi
  fi

  write_parameters_local
  mautic-config-sync push || die "could not store local.php in the database"
  # Keep the database copy current while the UI changes settings.
  mautic-config-sync push-loop &
}

cron_or_worker() {
  if [ -n "${RAILWAY_VOLUME_MOUNT_PATH:-}" ]; then
    log "note: a volume is attached to ${ROLE}; it is not needed (only the web service uses one)"
  fi
  wait_for_db
  local i=0
  # "exists" first: "pull" deliberately returns 0 when there is no remote copy yet.
  until mautic-config-sync exists && mautic-config-sync pull && [ -f "${CONFIG_DIR}/local.php" ]; do
    i=$((i + 1))
    [ $((i % 6)) -eq 1 ] && log "waiting for the web service to finish installing Mautic (local.php not in the database yet) ..."
    sleep 10
  done
  chown "${WWW_USER}:${WWW_USER}" "${CONFIG_DIR}/local.php"
  write_parameters_local
}

case "${ROLE}" in
  mautic_web) web ;;
  *) cron_or_worker ;;
esac

log "starting upstream entrypoint for ${ROLE}"
exec /entrypoint.sh "$@"
