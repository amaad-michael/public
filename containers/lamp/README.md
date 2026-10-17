# lamp — LAMP stack (httpd 2.4 + PHP-FPM 8.3 + MariaDB 10.11)

The container form of `scripts/provisioning/lamp-install-rocky10.sh`
and `lamp-install-debian13.sh` — the same stack the installers build
on bare metal: httpd 2.4 in front, PHP-FPM (PHP 8.3) behind it,
MariaDB 10.11 (the full-life stream the Rocky installer pins; it
rejects other streams) underneath. Three services on a private
network, hardened in the house style (cap_drop ALL,
no-new-privileges, read_only, resource limits, healthchecks).

- `web` — httpd:2.4, the only published service (host port 8083).
  The monitoring stack already publishes 8080/8081/8082 and the
  pihole stack 80/443 when stacks share a host, so 8083 is the next
  free slot.
- `php` — PHP-FPM 8.3, built from `php/Dockerfile`: the official
  php:8.3-fpm image plus the mysqli and pdo_mysql drivers. The stock
  image ships mysqlnd with no driver; the installers add the driver
  package (php-mysqlnd / php-mysql), and this build is the container
  equivalent. FastCGI on port 9000, network-internal only.
- `db` — mariadb:10.11, data on the `lamp_db` volume, port 3306
  network-internal only, never published.

Both `web` and `php` mount `./html` read-only at `/var/www/html` —
the shared path is what makes the FastCGI SCRIPT_FILENAME httpd
passes match the file PHP-FPM reads. The shipped `html/index.php` is
the canary (see Verification); replace it with the real site when
deploying something actual.

Configuration shipped with the stack:

- `httpd/httpd.conf` is the httpd:2.4 image's own default config
  with a five-line diff: proxy and proxy_fcgi modules enabled,
  DocumentRoot moved to /var/www/html, and an Include of
  `httpd/lamp.conf`, which carries the PHP handler. Because it tracks
  the image default, re-check the diff when the 2.4 image moves.
- Database credentials live only in the host-side `.env` (see
  Setup); compose refuses to start until they are set.

## 🛠️ Setup

1. Copy `lamp-env.example` to `.env`, generate both passwords at 32
   characters (Proton Pass, or `openssl rand -hex 16`), and
   `chmod 600 .env`. Compose refuses to start until
   `MYSQL_ROOT_PASSWORD`, `MYSQL_USER`, and `MYSQL_PASSWORD` are
   set.
1. Build and start the stack: `docker compose up -d --build`. First
   start initializes the MariaDB data volume with the database and
   user from `.env`; changing `.env` afterwards does not change the
   already-initialized database.
1. Verify before trusting it: run the canary in the Verification
   section.

## ✅ Verification (canary)

The installers end by proving PHP through httpd and MariaDB over its
socket; the shipped `html/index.php` is the same proof as a page. It
prints the PHP version, connects to MariaDB as the app user, and
runs `SELECT VERSION()`:

`curl -s http://localhost:8083/`

A healthy stack answers with three lines ending in `LAMP OK` (PHP
version, MariaDB 10.11.x version, LAMP OK). Any failure prints
`MariaDB FAIL` with the connection error and returns HTTP 500. The
web healthcheck requests the same page, so `docker compose ps`
shows the whole chain's health, not just httpd's.

## 💾 Backups

Everything stateful lives in the `lamp_db` volume. For a portable
logical backup:
`docker compose exec db mariadb-dump -u root -p lamp > lamp.sql`
(adjust the database name if `.env` sets a different one). The
docroot is this repo directory, so it is backed up with the repo
itself.
