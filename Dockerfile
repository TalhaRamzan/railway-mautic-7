# Thin wrapper around the official Mautic image for Railway.
#
# Why a wrapper instead of the plain image?
#   1. HTTP-API email: the official image ships only Symfony's built-in SMTP/sendmail
#      transports. Railway blocks outbound SMTP on Free/Trial/Hobby, so we add the
#      official Symfony mailer bridges (SES, Brevo, Mailgun, Postmark, Resend, SendGrid).
#   2. Railway volumes attach to ONE service. The wrapper installs Mautic headlessly on the
#      web service and syncs config/local.php to the cron + worker services through the
#      database, so settings saved in the UI reach every service.
#   3. Apache listens on $PORT, runs a small prefork pool (bill-shock protection) and hides
#      its version.
#   4. A complete cron schedule (the upstream one skips segment-email broadcasts).
#
# Upstream image: https://hub.docker.com/r/mautic/mautic  (pinned by tag AND digest)
# Bump procedure: see README.md -> "Upgrading".

ARG MAUTIC_IMAGE=mautic/mautic:7.2.2-20261119-apache@sha256:cb5a72a63c855917c2c6eca65cd368b02d8d491bc135d3834e85ba5d575d789c
FROM ${MAUTIC_IMAGE}

# Symfony mailer bridges, kept on the same minor line as symfony/mailer in Mautic 7.2 (7.4.x).
ARG MAILER_BRIDGES="symfony/amazon-mailer:~7.4.0 symfony/brevo-mailer:~7.4.0 symfony/mailgun-mailer:~7.4.0 symfony/postmark-mailer:~7.4.0 symfony/resend-mailer:~7.4.0 symfony/sendgrid-mailer:~7.4.0"

WORKDIR /var/www/html

# Composer plugins must stay enabled: composer/installers keeps Mautic's packages in their
# custom paths (with --no-plugins composer relocates them and bin/console breaks).
# --no-scripts skips the project's post-update scripts. The Symfony container cache is
# rebuilt afterwards so FrameworkBundle registers the new transport factories.
RUN set -eux; \
    COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_MEMORY_LIMIT=-1 \
      composer require --no-interaction --no-progress --no-scripts ${MAILER_BRIDGES}; \
    rm -rf /root/.composer /root/.cache/composer; \
    rm -rf var/cache/prod; \
    php bin/console cache:clear --no-interaction; \
    # only re-own files composer created as root (a blanket chown -R would copy all of vendor/ into a new layer)
    find var vendor composer.json composer.lock \! -user www-data -exec chown -h www-data:www-data {} +

# Apache: listen on $PORT (Railway), small prefork pool, no version banner.
RUN set -eux; \
    sed -ri 's/^Listen 80$/Listen ${PORT}/' /etc/apache2/ports.conf; \
    sed -ri 's/<VirtualHost \*:80>/<VirtualHost *:${PORT}>/' /etc/apache2/sites-available/000-default.conf; \
    grep -q 'Listen ${PORT}' /etc/apache2/ports.conf; \
    grep -q 'VirtualHost \*:${PORT}' /etc/apache2/sites-available/000-default.conf
COPY docker/apache-mpm-prefork.conf /etc/apache2/mods-available/mpm_prefork.conf
COPY docker/apache-hardening.conf /etc/apache2/conf-available/zz-railway-hardening.conf
RUN a2enconf zz-railway-hardening

# Cron schedule and worker supervisor config (read by the upstream role entrypoints).
COPY --chown=www-data:www-data --chmod=644 docker/mautic.crontab /templates/mautic_cron
COPY --chmod=644 docker/supervisord-worker.conf /etc/supervisor/conf.d/supervisord.conf

# Wrapper scripts.
COPY --chmod=755 docker/railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
COPY --chmod=755 docker/mautic-config-sync.sh /usr/local/bin/mautic-config-sync
COPY --chmod=644 docker/write-parameters-local.php /usr/local/lib/railway/write-parameters-local.php

# Lean defaults. Every value can be overridden per service in Railway.
ENV PORT=8080 \
    APACHE_START_SERVERS=2 \
    APACHE_MIN_SPARE_SERVERS=1 \
    APACHE_MAX_SPARE_SERVERS=3 \
    APACHE_MAX_REQUEST_WORKERS=10 \
    APACHE_MAX_CONNECTIONS_PER_CHILD=500 \
    DOCKER_MAUTIC_WORKERS_CONSUME_EMAIL=1 \
    DOCKER_MAUTIC_WORKERS_CONSUME_HIT=1 \
    DOCKER_MAUTIC_WORKERS_CONSUME_FAILED=1 \
    MAUTIC_MESSENGER_DSN_EMAIL=doctrine://default \
    MAUTIC_MESSENGER_DSN_HIT=doctrine://default \
    MAUTIC_DB_PORT=3306 \
    MAUTIC_DB_DATABASE=mautic \
    MAUTIC_DB_USER=mautic \
    ADMIN_USERNAME=admin \
    TRUSTED_PROXIES='["0.0.0.0/0","::/0"]' \
    PHP_INI_VALUE_DATE_TIMEZONE=UTC

EXPOSE 8080
WORKDIR /var/www/html/docroot
ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
