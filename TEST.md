# Test checklist

Three levels: static checks (done while writing the template), a local `docker compose`
run, and the real Railway deploy test (PLAN.md section 7, step 5).

## 1. Static checks

| Check | Command / source | Result (2026-11-21) |
|---|---|---|
| Compose file is valid | `docker compose config --quiet` | pass |
| Shell scripts parse | `bash -n docker/*.sh` | pass |
| Mautic tag + digest exist | Docker Hub API, `mautic/mautic` tag `7.2.2-20261119-apache` = `sha256:cb5a72a6...789c` (multi-arch index: amd64 + arm64) | pass |
| MariaDB tag + digest exist | Docker Hub API, `mariadb` tag `11.4.13` = `sha256:a8992b5e...309b` | pass |
| Mailpit tag + digest exist (local only) | Docker Hub API, `axllent/mailpit` tag `v1.33.1` = `sha256:aef2aacc...61ce` | pass |
| Upstream entrypoints in the pinned image match `mautic/docker-mautic` main | image layers downloaded from the registry and diffed | pass (identical) |
| Binaries used by the wrapper exist in the image | `runuser`, `mountpoint`, `base64`, `sha256sum`, `mariadb`, `mysqladmin`, `cron`, `supervisord` found in image layers | pass |
| Symfony bridges exist for the 7.4 line | Packagist: amazon 7.4.17, brevo 7.4.22, mailgun 7.4.18, postmark 7.4.18, resend 7.4.19, sendgrid 7.4.19; all require `symfony/mailer ^7.2` | pass |
| Console commands in the crontab exist in Mautic 7.2.2 | source of `mautic/mautic@7.2.2` (`segments:update`, `campaigns:update`, `campaigns:trigger`, `broadcasts:send`, `messages:send`, `reports:scheduler`, `unusedip:delete`) | pass |
| `messenger:consume` options `--time-limit --memory-limit --sleep` | Symfony 7.4 `ConsumeMessagesCommand` | pass |
| Mautic loads `parameters_local.php` after `local.php`, and `trusted_proxies` only from files | `ParameterLoader.php`, `ConfigAwareTrait.php` @7.2.2 | pass |
| Every variable in railway-template.md is documented in README.md | manual | pass |

## 2. Local run (docker compose)

```bash
cp .env.example .env        # fill passwords (12+ chars for ADMIN_PASSWORD)
docker compose up -d --build
docker compose logs -f mautic          # wait for "Mautic installed" then apache start
```

- [ ] Image builds (composer adds the 6 mailer bridges, cache clear succeeds).
- [ ] `docker compose exec mautic php /var/www/html/bin/console debug:container --env-vars >/dev/null` runs (container compiles).
- [ ] Web log: `installing Mautic ...` then `Mautic installed`, then Apache starts; healthcheck turns healthy.
- [ ] `http://localhost:${WEB_PORT}/s/login` shows the login page; log in with `ADMIN_USERNAME` / `ADMIN_PASSWORD`.
- [ ] Cron and worker logs: `pulled local.php`, then cron jobs / consumers start. No crash loop.
- [ ] `config/local.php` secret key is identical in all three containers:
      `docker compose exec <svc> grep secret_key /var/www/html/config/local.php`.
- [ ] Settings sync: change *Configuration > Email Settings > From name* in the UI, wait ~1 min,
      the cron container's `local.php` shows the new value.
- [ ] Email: *Send test email* arrives in Mailpit (`http://localhost:${MAILPIT_PORT}`).
- [ ] Queue: create a contact + segment + segment email, send; worker log shows consumption,
      Mailpit receives it; cron log shows `mautic:broadcasts:send`.
- [ ] Restart persistence: `docker compose down && docker compose up -d`; login works, contact still there, no reinstall.
- [ ] Recovery: `docker compose down`, delete only the `mautic_config` volume, `up -d` → web log says
      `restoring the copy stored in the database`, login works.
- [ ] Mailer bridge registered: `docker compose exec -u www-data mautic php /var/www/html/bin/console debug:container mailer.transport_factory.brevo` resolves.
- [ ] Cleanup: `docker compose down -v`.

## 3. Railway test (real deploy, keep it short: a few hours, then delete the project)

Build the template exactly as in [railway-template.md](railway-template.md), in a new project.

- [ ] All three Mautic services build from the repo; MariaDB starts with data in `/var/lib/mysql/data`.
- [ ] Reference variables resolve: `MAUTIC_DB_HOST` = `mariadb.railway.internal`-style host;
      `SITE_URL` on cron/worker equals the web service's `https://...` URL (nested reference
      `${{Mautic.SITE_URL}}` resolved, not the literal text).
- [ ] Web: install completes inside the 900 s healthcheck window; deployment turns Active.
- [ ] Volume layout: web log shows `persistent data directory: /data`; `/data/config/local.php` exists.
- [ ] Login over HTTPS works, no redirect loop, asset URLs are `https://` (trusted proxies OK).
- [ ] Email with a real HTTP API provider (e.g. Brevo or Resend free tier): test email from the
      UI arrives; a segment email sent via cron + worker arrives.
- [ ] Create a contact, a segment, a campaign; after 15-30 min cron logs show segment/campaign runs.
- [ ] Redeploy the web service: no reinstall, data intact, uploaded image still loads.
- [ ] Redeploy cron and worker: they pull config and continue.
- [ ] Memory graph after ~1 hour idle per service: record numbers in README > Monthly cost.
- [ ] Healthcheck on `/s/login` stays green.
- [ ] Delete the whole test project.

## 4. Not verified yet (needs a real run)

- Railway: digest syntax in the image field, nested reference variables, `lost+found`
  handling with the `--datadir` subfolder, healthcheck timing of the first install.
- Actual RAM/CPU usage numbers (README cost table is an estimate).
- HTTP API sending through each bridge against real provider accounts (only the local
  SMTP path to Mailpit is exercised locally).
- Bounce/complaint handling (not provided by the plain Symfony bridges).

## 5. Local run results (2026-11-21, OrbStack on macOS, linux/amd64)

Run with `docker compose -p mautic5test` on host ports 18080/18025, final Dockerfile.

| Step | Result |
|---|---|
| Image build | pass. Composer: "8 installs, 0 updates, 0 removals" (6 bridges + async-aws/core + async-aws/ses). Added layer about 99 MB. |
| First boot / headless install | pass. `mautic:install` done in about 15 s; web healthy 38 s after `up`. Only notice: "use HTTPS" (expected on localhost). |
| Admin login | pass. Login form POST to `/s/login_check` redirects (302) to `/s/dashboard`, which loads (200). |
| Create contact | pass. Contact form saved, redirected to `/s/contacts/view/1`, row in `leads`. |
| Config sync | pass. Same `local.php` sha256 and secret key on web, cron and worker. A change to web's `local.php` reached cron and worker in 27 s. |
| Worker (hit queue) | pass. Tracking-pixel hit queued in `messenger_messages`, consumed within 10 s, row in `page_hits`. (curl's default user agent is treated as a bot and ignored, so the test used a browser UA.) |
| Mailer from a non-web service | pass. `mailer:test` run in the cron container delivered to Mailpit using the forced `MAILER_DSN`. |
| HTTP API bridges registered | pass. `mailer.transport_factory.{amazon,brevo,mailgun,postmark,resend,sendgrid}` present in the compiled container. |
| Cron commands | pass. `segments:update`, `campaigns:update`, `campaigns:trigger`, `broadcasts:send`, `messages:send` and `reports:scheduler` each exit 0 with no errors when run as www-data with the cron environment. The crontab is installed with 11 jobs. Scheduled runs were not observed in the window. |
| Restart persistence | pass. `docker compose restart`: web logs "already installed, running migrations" (no reinstall), the contact is still there, login page 200. |
| Error scan | pass. No PHP warnings, fatals or exceptions in web, worker or cron logs. |
| Bug found and fixed | The cron/worker wait loop exited early because `pull` returns 0 when no remote copy exists; it now checks `exists` first. A plain `composer --no-plugins` broke Mautic's install paths, so it was removed. |

RAM at idle (`docker stats --no-stream`):

| Container | After first install | After restart |
|---|---|---|
| web (Apache + PHP) | 129 MiB | 67 MiB |
| worker (3 consumers + sync) | 154 MiB | 124 MiB |
| cron (between jobs) | 3 MiB | 2 MiB |
| MariaDB 11.4 | 126 MiB | 110 MiB |
| total without Mailpit | about 410 MiB | about 300 MiB |

Cron spikes to about 100-200 MiB while a job runs. Web grows with concurrent requests,
up to `APACHE_MAX_REQUEST_WORKERS` PHP processes.

Not covered locally: the Railway-only `/data` symlink layout, an HTTPS proxy, real API
providers and sustained load.

## Cron schedule check (2026-11-21, 18:22–18:33 UTC)
- PASS: cron fired on the clock without manual runs: `mautic:broadcasts:send` (at :27 and :32, output table "Channel / # sent / # failed") and `mautic:messages:send` (at :33, "Messages sent: 0"). `segments:update` (:30) produced no output on an empty install, which is normal.
- PASS: no errors or exceptions in cron or worker logs during the window.
