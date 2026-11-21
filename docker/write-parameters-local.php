<?php

/*
 * Writes config/parameters_local.php from environment variables.
 *
 * Mautic merges parameters_local.php AFTER local.php (see Mautic\CoreBundle\Loader\ParameterLoader
 * and app/middlewares/ConfigAwareTrait.php), so these values are "forced": they win over
 * anything saved in the UI. We only force what must be identical on web, cron and worker
 * (database, site URL, queues) plus a few optional overrides. Empty variables are skipped,
 * so an unset MAILER_DSN leaves the UI value in charge.
 *
 * Note: trusted_proxies is read by Mautic's TrustMiddleware from local.php and
 * parameters_local.php only (not from environment variables), which is why it lives here.
 *
 * Usage: php write-parameters-local.php /var/www/html/config/parameters_local.php
 */

declare(strict_types=1);

$target = $argv[1] ?? '';
if ('' === $target) {
    fwrite(STDERR, "usage: php write-parameters-local.php <target-file>\n");
    exit(2);
}

$env = static function (string $name): ?string {
    $value = getenv($name);
    if (false === $value) {
        return null;
    }
    $value = trim($value);

    return '' === $value ? null : $value;
};

$jsonList = static function (string $name) use ($env): ?array {
    $raw = $env($name);
    if (null === $raw) {
        return null;
    }
    $decoded = json_decode($raw, true);
    if (!is_array($decoded) || !array_is_list($decoded)) {
        fwrite(STDERR, "[railway] {$name} must be a JSON list, e.g. [\"0.0.0.0/0\",\"::/0\"]. Got: {$raw}\n");
        exit(1);
    }

    return array_values(array_map('strval', $decoded));
};

$parameters = [];

$map = [
    // Database (same variables the upstream image requires)
    'db_host'             => 'MAUTIC_DB_HOST',
    'db_port'             => 'MAUTIC_DB_PORT',
    'db_name'             => 'MAUTIC_DB_DATABASE',
    'db_user'             => 'MAUTIC_DB_USER',
    'db_password'         => 'MAUTIC_DB_PASSWORD',
    // Public URL; used for links in emails and tracking, so cron/worker need it too
    'site_url'            => 'SITE_URL',
    // Queues
    'messenger_dsn_email' => 'MAUTIC_MESSENGER_DSN_EMAIL',
    'messenger_dsn_hit'   => 'MAUTIC_MESSENGER_DSN_HIT',
    // Optional email overrides (leave empty to manage them in Configuration > Email Settings)
    'mailer_dsn'          => 'MAILER_DSN',
    'mailer_from_email'   => 'MAILER_FROM_EMAIL',
    'mailer_from_name'    => 'MAILER_FROM_NAME',
];

foreach ($map as $key => $var) {
    $value = $env($var);
    if (null !== $value) {
        $parameters[$key] = $value;
    }
}

if (isset($parameters['db_port'])) {
    $parameters['db_port'] = (int) $parameters['db_port'];
}

if (isset($parameters['site_url'])) {
    $parameters['site_url'] = rtrim($parameters['site_url'], '/');
    if (!preg_match('#^https?://[^/]+#', $parameters['site_url'])) {
        fwrite(STDERR, "[railway] SITE_URL must start with http:// or https:// (got: {$parameters['site_url']})\n");
        exit(1);
    }
}

if (isset($parameters['mailer_dsn']) && !preg_match('#^[a-z0-9+.-]+://#i', $parameters['mailer_dsn'])) {
    fwrite(STDERR, "[railway] MAILER_DSN does not look like a DSN (scheme://...). See README.md > Email.\n");
    exit(1);
}

if (null !== ($proxies = $jsonList('TRUSTED_PROXIES'))) {
    $parameters['trusted_proxies'] = $proxies;
}
if (null !== ($hosts = $jsonList('TRUSTED_HOSTS'))) {
    $parameters['trusted_hosts'] = $hosts;
}

// Mautic resolves "%name%" placeholders in parameters: escape literal percent signs
// (e.g. URL-encoded characters in a DSN password) the same way the UI does.
foreach (['db_password', 'mailer_dsn'] as $key) {
    if (isset($parameters[$key]) && is_string($parameters[$key])) {
        $parameters[$key] = str_replace('%', '%%', $parameters[$key]);
    }
}

$php = "<?php\n"
    ."// Generated at container start by write-parameters-local.php from environment variables.\n"
    ."// Do not edit: change the Railway variables instead. Values here override local.php.\n"
    .'$parameters = '.var_export($parameters, true).";\n";

$tmp = $target.'.tmp'.getmypid();
if (false === file_put_contents($tmp, $php)) {
    fwrite(STDERR, "[railway] cannot write {$tmp}\n");
    exit(1);
}
chmod($tmp, 0640);
if (!rename($tmp, $target)) {
    fwrite(STDERR, "[railway] cannot move {$tmp} to {$target}\n");
    exit(1);
}

fwrite(STDOUT, '[railway] wrote '.$target.' (forced keys: '.implode(', ', array_keys($parameters)).")\n");
