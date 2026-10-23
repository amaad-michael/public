# LAMP playbooks

One playbook that installs the LAMP stack — Apache, PHP-FPM, and
MariaDB — on either distro family. It is the Ansible form of the two
bash installers in `scripts/provisioning/`:

| Family | Bash installer | Target |
| --- | --- | --- |
| Debian | `lamp-install-debian13.sh` | pi2, Debian 13 (trixie), ARM64 |
| Rocky | `lamp-install-rocky10.sh` | pi3, Rocky 10.x, ARM64, SELinux enforcing |

The container form of the same stack is `containers/lamp/`.

## 🚀 Run

From the `ansible/` directory, against the `pi_lamp` group in
`ansible/hosts` (pi2 and pi3):

```bash
ansible-playbook -i hosts playbooks/lamp/lamp.yml -K
```

Scope to one host with `--limit pi2` or `--limit pi3` when only one
family should run.

## 🔁 How the two installers are reconciled

The playbook runs one play and branches on `ansible_os_family`, so a
mixed `pi_lamp` run gives each host exactly what its own bash
installer would give it:

- Packages: Debian installs `apache2`, `mariadb-server`, `php-fpm`,
  and `php-mysql`. Rocky installs `httpd`, `mariadb-server`, `php`,
  `php-fpm`, and `php-mysqlnd`. On Rocky the unversioned
  `mariadb-server` package is the 10.11 full-life stream (EOL 2035);
  the newer `mariadb11.8-server` stream is deliberately not used,
  and the verification below enforces that choice.
- PHP wiring: only the Debian installer wires Apache to PHP-FPM by
  hand — it detects the installed PHP version with
  `php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;'`, then
  runs `a2enmod proxy_fcgi setenvif` and `a2enconf php<version>-fpm`.
  The playbook does the same, in the same order. Rocky relies on the
  AppStream module defaults, as its installer does.
- Services: both families enable and start MariaDB, PHP-FPM, and the
  web server. Handlers restart a service only when a task that
  affects it changes: the package installs notify all three
  services, and the Debian `a2enmod`/`a2enconf` wiring notifies
  Apache — the change-triggered form of the Debian installer's
  `systemctl reload apache2`. An unchanged run restarts nothing.
- Firewall: neither form opens ports on an inactive firewall. The
  Debian branch allows 80/tcp and 443/tcp only when UFW reports
  active; the Rocky branch adds the firewalld `http` and `https`
  services and reloads only when firewalld is active.
- Verification (both families, same as the installers): print the
  web server, PHP, and MariaDB versions; confirm the services are
  active; write a throwaway PHP probe page into
  `/var/www/html/__lamp_check.php`, fetch it through the web server,
  and always remove it afterward (an Ansible `always` block, the
  equivalent of the installers' EXIT trap); then prove MariaDB
  socket authentication with `SELECT VERSION()`. The Rocky branch
  additionally fails the run if `mariadb --version` does not report
  the 10.11 stream, prints `getenforce`, and runs `restorecon` on
  the probe page before fetching it.

One wrapper difference: the Debian installer's
`timeout 120 apt-get update` has no direct apt-module equivalent, so
the playbook's cache update runs without the timeout wrapper. The
installed result is unchanged.
