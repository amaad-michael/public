#!/usr/bin/env bash
# lamp-install-rocky10.sh — pi3 (Rocky 10.x, ARM64, SELinux enforcing)
# httpd 2.4 + PHP-FPM (AppStream default 8.3) + MariaDB 10.11 (full-life stream, EOL 2035)
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

# 'mariadb-server' (unversioned) is the 10.11 full-life stream on EL10.
# The newer 11.8 stream ships as 'mariadb11.8-server' — NOT what we want here.
dnf -y install httpd mariadb-server php php-fpm php-mysqlnd

systemctl enable --now mariadb php-fpm httpd

# Firewall (firewalld)
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-service=http
  firewall-cmd --permanent --add-service=https
  firewall-cmd --reload
fi

# --- Verification -----------------------------------------------------------
echo "== versions =="
httpd -v | head -1
php -v | head -1
mariadb --version
mariadb --version | grep -q ' 10\.11\.' || { echo "FAIL: expected MariaDB 10.11 stream" >&2; exit 1; }

echo "== services =="
systemctl is-active httpd php-fpm mariadb

echo "== selinux =="
getenforce

echo "== php-fpm via httpd =="
TEST=/var/www/html/__lamp_check.php
printf '%s\n' '<?php echo "PHP ".PHP_VERSION." OK\n";' > "$TEST"
restorecon "$TEST"
curl -fsS http://127.0.0.1/__lamp_check.php
rm -f "$TEST"

echo "== mariadb socket auth =="
mariadb -e "SELECT VERSION();"

echo "LAMP OK"
