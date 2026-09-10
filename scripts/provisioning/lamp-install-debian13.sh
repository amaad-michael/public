#!/usr/bin/env bash
# lamp-install-debian13.sh — pi2 (Debian 13 / trixie, ARM64)
# Apache 2.4 + PHP-FPM (distro default 8.4) + MariaDB (distro default 11.8)
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y apache2 mariadb-server php-fpm php-mysql

# Detect installed PHP version for the fpm conf name (e.g. 8.4)
PHPV=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')

# Wire Apache -> PHP-FPM
a2enmod proxy_fcgi setenvif
a2enconf "php${PHPV}-fpm"

systemctl enable --now mariadb "php${PHPV}-fpm" apache2
systemctl reload apache2

# Firewall (UFW) — only touch if active
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  ufw allow 80/tcp
  ufw allow 443/tcp
fi

# --- Verification -----------------------------------------------------------
echo "== versions =="
apache2 -v | head -1
php -v | head -1
mariadb --version

echo "== services =="
systemctl is-active apache2 "php${PHPV}-fpm" mariadb

echo "== php-fpm via apache =="
TEST=/var/www/html/__lamp_check.php
echo '<?php echo "PHP ".PHP_VERSION." OK\n";' > "$TEST"
curl -fsS http://127.0.0.1/__lamp_check.php
rm -f "$TEST"

echo "== mariadb socket auth =="
mariadb -e "SELECT VERSION();"

echo "LAMP OK"
