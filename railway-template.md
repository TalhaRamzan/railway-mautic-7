# Railway template checklist (dashboard)

Exact settings to build the template in the Railway dashboard
(Workspace > Templates > New Template). Build it in a **separate test project**, never
in an existing production project. Service names matter: the variable references below
use `Mautic` and `MariaDB`.

Pinned versions (verified on Docker Hub, 2026-11-21):

| Component | Reference |
|---|---|
| Mautic base image (in `Dockerfile`) | `mautic/mautic:7.2.2-20261119-apache@sha256:cb5a72a63c855917c2c6eca65cd368b02d8d491bc135d3834e85ba5d575d789c` |
| MariaDB | `mariadb:11.4.13@sha256:a8992b5e5404d11e03c54a31d0c1bdea3fd116d283aa6d1a627551f29045309b` |

Random secrets use an explicit alphanumeric alphabet so they never need escaping:
`ALNUM` below means `"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"`,
e.g. `${{secret(32, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")}}`.

> **Published template:** https://railway.com/deploy/mautic-7 (published 2026-11-22).
>
> **How the published version was built** (Railway's template generator keeps only variables containing `${{...}}`
> and drops plain values): generated from a project with placeholder images, then the three Mautic services were
> switched to this GitHub repo in the template composer. Template variables are only secrets and references:
> `Mautic`: `SITE_URL`, `MAUTIC_DB_HOST`, `MAUTIC_DB_PASSWORD`, `ADMIN_PASSWORD`; cron/worker reference `Mautic.SITE_URL`
> and `Mautic.MAILER_*`. DB name/user/port, admin username, trusted proxies and timezone default in the Dockerfile;
> `ADMIN_EMAIL` defaults to `admin@example.com`. The role comes from each service's start command
> (`/bin/sh -c "export DOCKER_MAUTIC_ROLE=mautic_cron; exec /usr/local/bin/railway-entrypoint.sh"`).
> MariaDB's start command exports `MARIADB_DATABASE`/`MARIADB_USER` defaults. Railway injects `PORT=8080`; domain targets 8080.
> No healthcheck on the web service. Verified by deploying the template itself into an empty project with zero inputs.

---

## 1. Service `MariaDB`

- **Source:** Docker image `mariadb:11.4.13@sha256:a8992b5e5404d11e03c54a31d0c1bdea3fd116d283aa6d1a627551f29045309b`
  (if the image field rejects the digest form, use `mariadb:11.4.13`).
- **Start command:** `docker-entrypoint.sh mariadbd --datadir=/var/lib/mysql/data --skip-name-resolve`
  (data in a subfolder so the volume's `lost+found` is not seen as a database).
- **Volume:** mount path `/var/lib/mysql`.
- **Networking:** no public domain, no TCP proxy.
- **Healthcheck:** none (not HTTP).
- **Resource limit (recommended):** 1 GB RAM.
- **Variables:**

| Name | Value |
|---|---|
| `MARIADB_DATABASE` | `mautic` |
| `MARIADB_USER` | `mautic` |
| `MARIADB_PASSWORD` | `${{secret(32, ALNUM)}}` |
| `MARIADB_ROOT_PASSWORD` | `${{secret(32, ALNUM)}}` |

---

## 2. Service `Mautic` (web)

- **Source:** GitHub repo of this template, branch `main`, root directory `/`.
  Builder: Dockerfile (auto-detected from `/Dockerfile`).
- **Volume:** mount path `/data` (holds `config/`, `media/files`, `media/images`).
- **Networking:** Generate domain (HTTP), target port `8080`.
- **Healthcheck path:** `/s/login`
- **Healthcheck timeout:** `900` seconds (first boot installs Mautic).
- **Restart policy:** On failure, max 10 retries.
- **Serverless / app sleeping:** off (tracking pixels and forms must answer).
- **Replicas:** 1 (the volume allows only one).
- **Resource limit (recommended):** 1 GB RAM.
- **Variables:**

| Name | Value | Notes |
|---|---|---|
| `DOCKER_MAUTIC_ROLE` | `mautic_web` | |
| `PORT` | `8080` | |
| `SITE_URL` | `https://${{RAILWAY_PUBLIC_DOMAIN}}` | |
| `MAUTIC_DB_HOST` | `${{MariaDB.RAILWAY_PRIVATE_DOMAIN}}` | |
| `MAUTIC_DB_PORT` | `3306` | |
| `MAUTIC_DB_DATABASE` | `${{MariaDB.MARIADB_DATABASE}}` | |
| `MAUTIC_DB_USER` | `${{MariaDB.MARIADB_USER}}` | |
| `MAUTIC_DB_PASSWORD` | `${{MariaDB.MARIADB_PASSWORD}}` | |
| `ADMIN_EMAIL` | *(optional)* | Description: "Email of the first Mautic admin (default admin@example.com)" |
| `ADMIN_USERNAME` | `admin` | |
| `ADMIN_PASSWORD` | `${{secret(24, ALNUM)}}` | |
| `MAILER_DSN` | *(empty, optional)* | Description: "HTTP API email DSN, e.g. brevo+api://KEY@default. See README." |
| `MAILER_FROM_EMAIL` | *(empty, optional)* | Description: "Sender address on your verified domain" |
| `MAILER_FROM_NAME` | *(empty, optional)* | |
| `TRUSTED_PROXIES` | `["0.0.0.0/0","::/0"]` | JSON list |
| `PHP_INI_VALUE_DATE_TIMEZONE` | `UTC` | |

---

## 3. Service `Mautic Cron`

- **Source:** same GitHub repo, branch and root directory as `Mautic`.
- **Volume:** none.
- **Networking:** none (no domain, no TCP proxy).
- **Healthcheck:** none.
- **Restart policy:** Always.
- **Serverless / app sleeping:** off.
- **Resource limit (recommended):** 512 MB RAM.
- **Variables:**

| Name | Value |
|---|---|
| `DOCKER_MAUTIC_ROLE` | `mautic_cron` |
| `SITE_URL` | `${{Mautic.SITE_URL}}` |
| `MAUTIC_DB_HOST` | `${{MariaDB.RAILWAY_PRIVATE_DOMAIN}}` |
| `MAUTIC_DB_PORT` | `3306` |
| `MAUTIC_DB_DATABASE` | `${{MariaDB.MARIADB_DATABASE}}` |
| `MAUTIC_DB_USER` | `${{MariaDB.MARIADB_USER}}` |
| `MAUTIC_DB_PASSWORD` | `${{MariaDB.MARIADB_PASSWORD}}` |
| `MAILER_DSN` | `${{Mautic.MAILER_DSN}}` |
| `MAILER_FROM_EMAIL` | `${{Mautic.MAILER_FROM_EMAIL}}` |
| `MAILER_FROM_NAME` | `${{Mautic.MAILER_FROM_NAME}}` |
| `PHP_INI_VALUE_DATE_TIMEZONE` | `${{Mautic.PHP_INI_VALUE_DATE_TIMEZONE}}` |

---

## 4. Service `Mautic Worker`

- **Source:** same GitHub repo, branch and root directory as `Mautic`.
- **Volume:** none. **Networking:** none. **Healthcheck:** none.
- **Restart policy:** Always. **Serverless:** off.
- **Resource limit (recommended):** 512 MB RAM.
- **Variables:** the same table as `Mautic Cron`, except:

| Name | Value |
|---|---|
| `DOCKER_MAUTIC_ROLE` | `mautic_worker` |
| `DOCKER_MAUTIC_WORKERS_CONSUME_EMAIL` | `1` |
| `DOCKER_MAUTIC_WORKERS_CONSUME_HIT` | `1` |
| `DOCKER_MAUTIC_WORKERS_CONSUME_FAILED` | `1` |

---

## 5. Template metadata

- **Name:** `Mautic 7 | Open-Source HubSpot Alternative (Cron + Worker + API Email)`
  (PLAN.md proposed "Mautic 5"; 5.x is out of public security support, see README > Versions.)
- **Short description:** `Self-hosted Mautic 7.2 marketing automation with separate cron and queue worker, HTTP-API email that works on Hobby (no SMTP), auto-install and pinned versions. [Updated Nov '26]`
- **Category:** Marketing / Automation.
- **Tags:** `mautic`, `marketing-automation`, `email-marketing`, `hubspot-alternative`, `crm`, `newsletter`, `php`, `mariadb`.
- **Icon:** a neutral generic icon (no Mautic logo, per our repo rules).
- **Overview / README:** paste the top of README.md (Architecture, After deploying, Email setup, Monthly cost).
- Turn on Template Queue email notifications.

## 6. Before publishing

- [ ] Every image/tag in this file matches the `Dockerfile` and `docker-compose.yml`.
- [ ] No variable has a real secret or personal value; only `${{secret()}}`, references or empty.
- [ ] Run the full Railway checklist in TEST.md, then delete the test project.
- [ ] Title/description carry the current "[Updated <Mon 'YY>]" tag.
