# Mautic on Railway: web + cron + worker + HTTP API email

Self-hosted [Mautic](https://www.mautic.org) (open-source marketing automation, an
alternative to HubSpot / ActiveCampaign / Mailchimp automations) as a Railway template:

- **Mautic 7.2.2** (current supported line) on the official `mautic/mautic` Apache image, pinned by tag **and** digest
- **Separate cron and worker services** so campaigns, segments and segment emails actually run
- **Email over HTTPS APIs** (Amazon SES, Brevo, Mailgun, Postmark, Resend, SendGrid): works on Railway Hobby, where outbound SMTP is blocked
- **No public install wizard**: Mautic installs itself on first boot with a random admin password
- **Settings saved in the UI reach cron and worker** (config is synced through the database)
- Lean defaults: small Apache pool, 1 queue consumer each, MariaDB 11.4 LTS

> **Unofficial community template.** Not affiliated with or endorsed by the Mautic project.
> Mautic is GPL-3.0 software by its contributors; this repository only contains deployment
> files (MIT, see [LICENSE](LICENSE)).

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/mautic-7)

---

## Contents

1. [Architecture](#architecture)
2. [After deploying](#after-deploying)
3. [Email setup](#email-setup-required-to-send)
4. [Monthly cost](#monthly-cost-estimate)
5. [Variables](#variables)
6. [How config reaches cron and worker](#how-config-reaches-cron-and-worker)
7. [Limitations](#limitations)
8. [Upgrading](#upgrading)
9. [Backup & restore](#backup--restore)
10. [Troubleshooting](#troubleshooting)
11. [Versions, why "Mautic 7"](#versions)
12. [Credits](#credits)

---

## Architecture

```
                  Internet (HTTPS, Railway edge)
                              |
                     +--------v--------+        volume /data
                     |  Mautic (web)   |------  config/local.php, media/files, media/images
                     |  apache, :8080  |
                     +--------+--------+
       pushes local.php       |
       into the database      |   private network (mariadb.railway.internal)
                     +--------v--------+
                     |    MariaDB      |------  volume /var/lib/mysql
                     |   11.4 LTS      |
                     +---+---------+---+
            pulls        |         |        pulls
          local.php      |         |      local.php
           +-------------+--+   +--+--------------+
           |  Mautic Cron   |   |  Mautic Worker  |
           |  segments,     |   |  email + hit    |
           |  campaigns,    |   |  queues         |
           |  broadcasts    |   |  (supervisord)  |
           +----------------+   +-----------------+
```

All three Mautic services build the same `Dockerfile` (official image + Symfony mailer
bridges + small wrapper). `DOCKER_MAUTIC_ROLE` picks the role.

| Service | Role | Public | Volume | What it does |
|---|---|---|---|---|
| **Mautic** | `mautic_web` | yes (HTTPS) | `/data` | UI, tracking pixel, forms, landing pages, API. Installs Mautic on first boot and runs database migrations on every start. |
| **Mautic Cron** | `mautic_cron` | no | none | Segment rebuilds, campaign updates/triggers, segment (broadcast) emails, scheduled reports. |
| **Mautic Worker** | `mautic_worker` | no | none | Sends queued emails and records page/email hits from the database queue. |
| **MariaDB** | database | no | `/var/lib/mysql` | All contacts, campaigns, emails, stats and the queues. |

### Cron schedule (UTC)

| When | Command |
|---|---|
| every minute | pull `local.php` from the database |
| :00 :15 :30 :45 | `mautic:segments:update` |
| :05 :20 :35 :50 | `mautic:campaigns:update` |
| :10 :25 :40 :55 | `mautic:campaigns:trigger` |
| every 5 min (:02, :07, ...) | `mautic:broadcasts:send` (segment emails; the upstream image does not schedule this) |
| :03 :18 :33 :48 | `mautic:messages:send` |
| hourly :14 | `mautic:reports:scheduler` |
| daily 04:23 | `mautic:unusedip:delete` |

Optional jobs (IMAP bounce monitoring, queued webhooks, A/B winner, MaxMind download) are
listed, commented out, in [`docker/mautic.crontab`](docker/mautic.crontab).

---

## After deploying

1. The first deploy builds the image three times (once per Mautic service) and the web
   service then installs Mautic. **Expect 5-10 minutes** before the URL answers.
   Cron and worker log `waiting for the web service to finish installing` until then; that is normal.
2. Open `https://<your-domain>/s/login`.
   - Username: `admin` (variable `ADMIN_USERNAME`)
   - Password: the `ADMIN_PASSWORD` variable on the **Mautic** service (Variables tab, click the eye icon).
3. Change the password in Mautic (top right > Account), then set up email (next section).
4. Optional: add a custom domain to the **Mautic** service and update `SITE_URL` (see
   [Custom domain](#custom-domain)).

`ADMIN_EMAIL`, `ADMIN_PASSWORD` and `ADMIN_USERNAME` are only read on the very first boot.
Changing them later does nothing; change the account inside Mautic instead.

---

## Email setup (required to send)

Railway blocks outbound SMTP (ports 25/465/587) on Free, Trial and Hobby plans, so Mautic's
default SMTP setup cannot send. This template ships the official Symfony HTTP API
transports instead. Pick a provider, create an API key, verify your sending domain
(SPF/DKIM) with the provider, then set **one** variable on the **Mautic** service:

| Provider | `MAILER_DSN` value |
|---|---|
| Brevo | `brevo+api://API_KEY@default` |
| Postmark | `postmark+api://SERVER_TOKEN@default` |
| Resend | `resend+api://API_KEY@default` |
| Amazon SES | `ses+api://ACCESS_KEY_ID:SECRET_ACCESS_KEY@default?region=eu-west-1` |
| SendGrid | `sendgrid+api://API_KEY@default` |
| Mailgun | `mailgun+api://API_KEY:YOUR_DOMAIN@default?region=us` (or `region=eu`) |

Also set `MAILER_FROM_EMAIL` (an address on your verified domain) and `MAILER_FROM_NAME`.
Cron and worker reference these variables, so redeploying the **Mautic**, **Mautic Cron**
and **Mautic Worker** services applies them everywhere.

Rules for the DSN:

- **URL-encode special characters** in keys and secrets: `/` → `%2F`, `+` → `%2B`,
  `=` → `%3D`, `@` → `%40`, `:` → `%3A`. Amazon SES secret keys often contain `/` and `+`.
- While `MAILER_DSN` is set, the transport fields under *Configuration > Email Settings*
  are ignored (the variable wins). Leave `MAILER_DSN` empty if you prefer to manage the
  transport in the UI; the sync described below then carries it to cron and worker.
- On a Railway **Pro** plan SMTP works, so `smtp://user:pass@smtp.example.com:587` is fine too.
- Test with *Configuration > Email Settings > Send test email*, then send a real email to
  yourself from a segment to exercise the worker.

### Bounces, complaints and unsubscribes

The API transports above are **send-only**. Mautic hands each message to the provider and
gets an "accepted" back; nothing flows the other way. Hard bounces, spam complaints and
unsubscribes made through the provider (for example a one-click `List-Unsubscribe` handled
by the provider) are **not** fed back into Mautic, so those contacts stay "active" and keep
getting campaign emails.

That is fine for testing and small lists. For production sending, pick one of these:

- **A Mautic provider plugin** with webhook feedback, for example the Amazon SES or
  SendGrid integrations from the Mautic Marketplace (*Settings > Marketplace*) or the
  provider's own plugin. They point the provider's bounce/complaint webhook (or SNS
  topic for SES) at your Mautic URL and mark contacts as bounced/unsubscribed. Marketplace
  plugins installed from the UI are lost on redeploy, so add the plugin to the `Dockerfile`
  (see [Limitations](#limitations)) and check that it supports Mautic 7.
- **IMAP bounce monitoring:** point the provider's bounce/return-path address at a mailbox,
  set it under *Configuration > Email Settings > Monitored inbox*, and enable the commented
  `mautic:email:fetch` job in [`docker/mautic.crontab`](docker/mautic.crontab) in your fork.
- At minimum, keep the provider's **suppression list** on (it stops resends to bounced
  addresses even though Mautic does not know about them) and watch its bounce/complaint
  rates.

---

## Monthly cost (estimate)

Railway bills usage: RAM about $10 per GB-month, CPU about $20 per vCPU-month, volumes about
$0.15 per GB-month (check [railway.com/pricing](https://railway.com/pricing); prices can change).
Idle footprint measured in a local run (see [TEST.md](TEST.md) section 5). A Railway test deploy measured ~0.47 GB idle in total (web ~140 MB, worker ~136 MB, cron ~5 MB, MariaDB ~187 MB), about $5/month of RAM:

| Service | Idle RAM (measured locally) | Notes |
|---|---|---|
| Mautic (web) | 70-130 MB | Grows with traffic; capped at 10 PHP processes (`APACHE_MAX_REQUEST_WORKERS`) |
| Mautic Cron | ~3 MB, 100-200 MB while a job runs | Jobs are staggered |
| Mautic Worker | 125-155 MB | 3 consumers (email, hit, failed), each restarts every 10-15 min |
| MariaDB | 110-130 MB | MariaDB defaults (128 MB InnoDB buffer pool) |
| **Total** | **~0.3-0.45 GB idle**, ~0.6-1 GB busy | |

**Roughly $5-12 per month** for a small list (a few thousand contacts, a few campaigns), of
which the Hobby plan's included $5 covers part. Big imports, very large segments and heavy
tracking traffic use more CPU and RAM. To keep the bill predictable:

- Set memory limits per service (Settings > Deploy > Resource limits): web 1 GB, cron 512 MB, worker 512 MB, MariaDB 1 GB.
- Keep `DOCKER_MAUTIC_WORKERS_CONSUME_*` at 1 unless you send large volumes.
- Keep the stats tables small with the optional `mautic:maintenance:cleanup` job (deletes old anonymous data; read the Mautic docs first).

---

## Variables

### Mautic (web)

| Variable | Default in template | Purpose |
|---|---|---|
| `DOCKER_MAUTIC_ROLE` | `mautic_web` | Role. Do not change. |
| `PORT` | `8080` | Port Apache listens on. |
| `SITE_URL` | `https://${{RAILWAY_PUBLIC_DOMAIN}}` | Public URL used in links, emails and tracking. No trailing slash. |
| `MAUTIC_DB_HOST` | `${{MariaDB.RAILWAY_PRIVATE_DOMAIN}}` | Database host (private network). |
| `MAUTIC_DB_PORT` | `3306` | |
| `MAUTIC_DB_DATABASE` | `${{MariaDB.MARIADB_DATABASE}}` | |
| `MAUTIC_DB_USER` | `${{MariaDB.MARIADB_USER}}` | |
| `MAUTIC_DB_PASSWORD` | `${{MariaDB.MARIADB_PASSWORD}}` | |
| `ADMIN_EMAIL` | *(optional)* | First admin's email. Falls back to `admin@example.com` if unset (change it in Mautic after login). First boot only. |
| `ADMIN_USERNAME` | `admin` | First boot only. |
| `ADMIN_PASSWORD` | `${{secret(24, ...)}}` | Random. First boot only. |
| `MAILER_DSN` | *(empty)* | HTTP API transport, see [Email setup](#email-setup-required-to-send). |
| `MAILER_FROM_EMAIL` / `MAILER_FROM_NAME` | *(empty)* | Default sender. Empty = managed in the UI. |
| `TRUSTED_PROXIES` | `["0.0.0.0/0","::/0"]` | JSON list. Needed so Mautic sees HTTPS behind Railway's proxy. Narrow it outside Railway, see [Trusted proxies and hosts](#trusted-proxies-and-hosts-non-railway-or-custom-setups). |
| `TRUSTED_HOSTS` | *(unset)* | Optional JSON list of allowed host names (regex), e.g. `["^mautic\\.example\\.com$"]`. Keep `^healthcheck\\.railway\\.app$` in it on Railway. |
| `PHP_INI_VALUE_DATE_TIMEZONE` | `UTC` | PHP timezone. |
| `PHP_INI_VALUE_MEMORY_LIMIT` | `512M` | Per PHP process. |
| `APACHE_MAX_REQUEST_WORKERS` | `10` (image default) | Max concurrent PHP requests; main RAM cap of the web service. |
| `ADOPT_EXISTING_DB` | *(unset)* | Recovery switch, see [Backup & restore](#backup--restore). |

### Mautic Cron / Mautic Worker

Same database, `SITE_URL`, `MAILER_*` and timezone variables, as references to the Mautic
service (for example `SITE_URL=${{Mautic.SITE_URL}}`), plus:

| Variable | Service | Default | Purpose |
|---|---|---|---|
| `DOCKER_MAUTIC_ROLE` | cron / worker | `mautic_cron` / `mautic_worker` | Role. |
| `DOCKER_MAUTIC_WORKERS_CONSUME_EMAIL` | worker | `1` | Email queue consumers. Raise to 2-3 for large sends. |
| `DOCKER_MAUTIC_WORKERS_CONSUME_HIT` | worker | `1` | Page/email hit consumers. |
| `DOCKER_MAUTIC_WORKERS_CONSUME_FAILED` | worker | `1` | Retries failed messages. |

Queues use the database (`MAUTIC_MESSENGER_DSN_EMAIL` / `_HIT` = `doctrine://default`, set in the image).

---

## How config reaches cron and worker

Mautic keeps its settings and its encryption key in `config/local.php`, and rewrites that
file whenever an admin saves *Configuration*. Railway volumes attach to one service only,
so cron and worker cannot read the web service's file. Other multi-service templates
regenerate a partial config from environment variables; settings changed in the UI then
silently differ between services (for example the sender address or tracking options used
by campaign emails).

This template:

1. **Web** installs Mautic, then stores `local.php` in a one-row table
   (`railway_config_sync`) and re-uploads it within 30 seconds of any change.
2. **Cron** pulls it every minute; **worker** pulls it every 30 seconds and its queue
   consumers restart every 10 minutes, so they pick up changes without a redeploy.
3. Each service also writes `config/parameters_local.php` from its own variables. Mautic
   loads it after `local.php`, so the database connection, `SITE_URL`, the queues and the
   optional `MAILER_*` / `TRUSTED_PROXIES` variables always win over UI values.

If the web volume is ever lost, the web service restores `local.php` from that table on the
next boot.

---

## Limitations

- **Background contact import/export:** use **Import in browser**. Background imports and
  scheduled exports write files on the web service, which the cron service cannot read.
- **Email attachments from Assets:** files uploaded as Assets live on the web volume. Emails
  sent by the worker can link to assets but not attach them.
- **Uploaded media** (images, files) persist on the web volume; logs (`var/logs`) do not
  persist across redeploys (Railway keeps stdout logs).
- **Marketplace plugins / custom themes** installed from the UI are lost on redeploy (code
  is not on the volume). Add them to the `Dockerfile` instead (see the upstream
  "custom-plugins" example).
- **One web replica.** The volume prevents horizontal scaling of the web service.
- Bounce, complaint and unsubscribe feedback from the provider is not wired up (see
  [Bounces, complaints and unsubscribes](#bounces-complaints-and-unsubscribes)).

---

## Upgrading

The Mautic version is pinned in the `Dockerfile` (`ARG MAUTIC_IMAGE=...`, tag + digest).

1. **Back up first** (see below). Database migrations run automatically when the web service starts.
2. Read the [Mautic release notes](https://github.com/mautic/mautic/releases) for the new version.
   Patch releases (7.2.x) are routine. Minor/major releases can require newer PHP or database
   versions and can break third-party plugins.
3. Find the new tag and digest:
   ```bash
   curl -s "https://hub.docker.com/v2/repositories/mautic/mautic/tags?page_size=50&name=apache" \
     | python3 -c 'import json,sys;[print(t["name"],t["digest"]) for t in json.load(sys.stdin)["results"]]'
   ```
   Prefer the dated tag (`7.2.3-YYYYMMDD-apache`) and its digest.
4. Update `ARG MAUTIC_IMAGE` (and the `~7.4.0` mailer bridge constraint if Mautic moves to a
   new Symfony line; check `symfony/mailer` in Mautic's `app/composer.json`).
5. Test locally with `docker compose up -d --build` (see [TEST.md](TEST.md)), push, and
   let Railway redeploy. Deploy order does not matter: cron and worker tolerate a few
   failed runs while the web service migrates.
6. Upgrade one major version at a time (5.2 → 6.0 → 7.x), as the Mautic docs recommend.

**Coming from a Mautic 5 deployment?** Upgrade the old instance to the latest 6.0 first,
take a dump, import it into this template's MariaDB and start the web service once with
`ADOPT_EXISTING_DB=true` (or with your old `local.php` in `/data/config/`). The 7.2
migrations run on start. Rehearse this on a copy before doing it for real.

---

## Backup & restore

Data lives in two places: the **MariaDB volume** (everything important) and the **web
volume** (`/data`: `config/local.php` and uploaded media).

> **Treat database backups like secrets.** Because `config/local.php` is synced through
> the database (table `railway_config_sync`, see
> [How config reaches cron and worker](#how-config-reaches-cron-and-worker)), every dump
> or volume backup of MariaDB contains Mautic's **secret key** together with the data it
> encrypts (plugin/integration credentials), plus any mail transport settings saved in
> the UI, which can include the provider API key. Anyone with the dump can read those.
> Store dumps encrypted (for example `gpg -c` or an encrypted bucket), keep them off
> shared drives and chat, delete old ones, and rotate the provider API key if a dump
> leaks. Keys set only in the `MAILER_DSN` variable live in Railway, not in the dump,
> unless you also save *Email Settings* in the UI.

- Enable Railway volume backups on both volumes (service > Backups), if your plan has them.
- Logical dump: temporarily enable **TCP Proxy** on the MariaDB service (Settings >
  Networking), then from your machine:
  ```bash
  mariadb-dump --single-transaction --routines -h <proxy-host> -P <proxy-port> \
    -u root -p mautic > mautic-$(date +%F).sql   # password: MARIADB_ROOT_PASSWORD
  ```
  Disable the TCP proxy again afterwards so the database is not reachable from the internet.
- Media: the web volume holds uploaded images/files; Railway volume backups cover it.
- **Restore into a fresh deploy:** import the dump into MariaDB *before* the web service
  installs (or wipe the new install), then start the web service with
  `ADOPT_EXISTING_DB=true` once. It writes a minimal `local.php` (new secret key) for the
  existing data; integration secrets encrypted with the old key must be re-entered.
  Remove the variable afterwards. If you still have the old `local.php`, put it in
  `/data/config/` instead and keep the old secret key.

---

## Troubleshooting

### `AH00534: apache2: Configuration error: More than one MPM loaded`
Railway's runtime can end up with a second Apache MPM enabled next to `mpm_prefork`. The entrypoint now removes `mpm_event` / `mpm_worker` from `mods-enabled` on every boot of the web service, so this should not happen with this template. If you build your own image from it, keep that step.

| Symptom | Fix |
|---|---|
| Web deploy fails healthcheck on the first deploy | The install can take a few minutes; the healthcheck timeout should be 900 s (see railway-template.md). Check the web logs for `mautic:install failed`. |
| `the database already contains Mautic data but there is no local.php` | The volume is empty but the database is not (and no synced copy exists). Restore `local.php`, or set `ADOPT_EXISTING_DB=true` once. If the very first install crashed halfway, deleting and recreating the MariaDB volume is the clean fix. |
| Cron/worker stuck on `waiting for the web service` | The web service has not finished installing, or cron/worker point at a different database. Compare the `MAUTIC_DB_*` values. |
| Emails stay "pending" | The worker is not running, or `MAILER_DSN` is wrong. Worker logs show the transport error. |
| Segment emails never go out | Check the cron logs for `mautic:broadcasts:send`. |
| Redirect loops or `http://` links | `SITE_URL` must be `https://...` and `TRUSTED_PROXIES` must be set. |
| Out-of-memory restarts | Raise the service memory limit or lower `APACHE_MAX_REQUEST_WORKERS` / worker counts. |
| Forgot the admin password | Use *Forgot password* on the login page (needs working email), or reset it in the database with a bcrypt hash. |

### Custom domain

Add the domain to the **Mautic** service, then set `SITE_URL=https://your.domain` on the
Mautic service. Cron and worker reference it; redeploy all three services. Links in emails
already sent keep the old domain, so keep the Railway domain working too.

### Trusted proxies and hosts (non-Railway or custom setups)

`TRUSTED_PROXIES` tells Mautic which upstream addresses may set `X-Forwarded-For` /
`X-Forwarded-Proto`. The template default, `["0.0.0.0/0","::/0"]`, trusts every address.
That is acceptable on Railway because the container has no public port: all traffic arrives
through Railway's edge, which has no fixed, documented address range. Anywhere else it is
too broad: if clients can reach Mautic directly, they can spoof their IP (contact tracking, IP
lookups, IP-based rules) and the HTTPS scheme.

If you run this image behind your own reverse proxy, on a VPS, or behind another platform,
narrow it to the proxy's address(es), as a JSON list of IPs or CIDRs:

| Setup | `TRUSTED_PROXIES` |
|---|---|
| nginx/Caddy/Traefik on the same host, Mautic published on localhost | `["127.0.0.1","::1"]` |
| Proxy on a Docker network | the network's subnet, e.g. `["172.18.0.0/16"]` (`docker network inspect <net>`) |
| Cloudflare in front, origin firewalled to Cloudflare | Cloudflare's published ranges ([cloudflare.com/ips](https://www.cloudflare.com/ips/)) |
| Load balancer in a private VPC | the VPC/subnet CIDR, e.g. `["10.0.0.0/16"]` |

`TRUSTED_HOSTS` (unset by default) limits which `Host` headers Mautic answers, which blocks
host-header tricks such as poisoned password-reset links. Values are regular expressions
in a JSON list. Escape dots and anchor them:

```
TRUSTED_HOSTS=["^mautic\\.example\\.com$","^[a-z0-9-]+\\.up\\.railway\\.app$","^healthcheck\\.railway\\.app$"]
```

- Include **every** domain that serves Mautic (custom domain and, while emails with old
  links are out there, the Railway domain). Requests for other hosts get HTTP 400.
- On Railway keep the `healthcheck.railway.app` entry: Railway's healthcheck sends that
  `Host` header, and without it every deploy fails its healthcheck.
- Both variables are read on container start (into `parameters_local.php`); redeploy the
  Mautic service after changing them. Invalid JSON stops the container with an error in
  the deploy log.

---

## Versions

| Component | Pinned version |
|---|---|
| Mautic image | `mautic/mautic:7.2.2-20261119-apache@sha256:cb5a72a63c855917c2c6eca65cd368b02d8d491bc135d3834e85ba5d575d789c` (PHP 8.3) |
| MariaDB | `mariadb:11.4.13@sha256:a8992b5e5404d11e03c54a31d0c1bdea3fd116d283aa6d1a627551f29045309b` (11.4 LTS) |
| Symfony mailer bridges | `~7.4.0` (same line as `symfony/mailer` in Mautic 7.2) |

**Why Mautic 7 and not Mautic 5?** Per [mautic.org/releases](https://mautic.org/releases),
public security support for 5.2 ended on 30 June 2026 and for 6.0 on 30 September 2026
(only paid Extended LTS continues). 7.2 is the actively supported line. Mautic 7 needs
MySQL 8.4+ or MariaDB 10.11+; this template uses MariaDB 11.4 LTS, which Mautic's own CI
tests.

---

## Credits

- [Mautic](https://github.com/mautic/mautic) (GPL-3.0) and the
  [official Docker image](https://github.com/mautic/docker-mautic), whose role-based
  entrypoints (`mautic_web`, `mautic_cron`, `mautic_worker`) this template wraps.
- [Symfony Mailer](https://symfony.com/doc/current/mailer.html) bridges (MIT).
- [MariaDB](https://mariadb.org) (GPL-2.0).

Template files: MIT, see [LICENSE](LICENSE). Questions: open an issue or use the Railway
template page.
