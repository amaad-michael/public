#!/usr/bin/env bash
# neo1 observability — native install (ARMv7 / Armbian, systemd)
# ZERO-GUESSWORK GATE: script refuses to run until versions + checksums are set.
# Pins below were resolved from upstream release pages on 2026-10-18;
# every sha256 is the linux-armv7 value from the project's official
# SHA256SUMS / checksums file. To bump: update version AND sha256
# together, from the same release's checksum file — never from memory.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root"; exit 1; }

# Configs and units are referenced relative to the kit root.
cd "$(dirname "$0")/.."

### ---- PINS (verify against the release's checksum file before bumping) ----
PROM_VERSION="3.15.0"            # prometheus-…linux-armv7.tar.gz
PROM_SHA256="66c26d503b8600fd512f9fddf6937f37597c4d35cc162c329b8a6c3c7d67def0"
AM_VERSION="0.34.1"              # alertmanager-…linux-armv7.tar.gz
AM_SHA256="75f568dc43b3f905cc846e71417bbcc1d63d186bc7d95bd87fd2f41b1124d4f3"
BB_VERSION="0.29.0"              # blackbox_exporter-…linux-armv7.tar.gz
BB_SHA256="8f8a318cf3be2eed347c52d0e91e3297f8eaedb6d03720cc10868b7c753f38cb"
NE_VERSION="1.12.1"              # node_exporter-…linux-armv7.tar.gz
NE_SHA256="ae3d72fbf77f9ebed553c24465310e0880383f45d3d1566357ce7a31a997acb2"
NTFY_VERSION="2.32.0"            # ntfy_…_linux_armv7.tar.gz
NTFY_SHA256="feda554c21ef68176b0defa704815eec64d5751557fa16eb041de778d9c2b476"
# Grafana: the armhf (linux-armv7) tarball was verified to exist for
# this version; Grafana has wavered on 32-bit ARM — re-verify on bump.
GRAFANA_VERSION="13.2.4"         # grafana-…linux-armv7.tar.gz (dl.grafana.com)
GRAFANA_SHA256="e157812666d3a275f43452c83eefd8d0a5bf9c067275e8a7a7d5b0b579d169cb"
### --------------------------------------------------------------------

for v in PROM_VERSION PROM_SHA256 AM_VERSION AM_SHA256 BB_VERSION BB_SHA256 \
         NE_VERSION NE_SHA256 NTFY_VERSION NTFY_SHA256 \
         GRAFANA_VERSION GRAFANA_SHA256; do
  [[ -n "${!v}" ]] || { echo "ABORT: $v unset — verify and pin versions first."; exit 1; }
done

ARCH=armv7
# Download directory: ${TMPDIR:-/tmp}/neo1-dl. TMPDIR is honored
# because a small tmpfs /tmp cannot hold the download set — neo1's
# /tmp is 243 MB, while the six pinned tarballs total ~602 MiB
# (630,675,418 bytes, measured 2026-10-25) before extraction. With
# TMPDIR unset the path is /tmp/neo1-dl, exactly as before.
DL="${TMPDIR:-/tmp}/neo1-dl"
mkdir -p "$DL"
# Fail early — before any download or system change — when the
# filesystem holding DL cannot hold the set plus extraction room.
DL_AVAIL_KB=$(df -Pk "$DL" | awk 'NR==2 {print $4}')
if [ "$DL_AVAIL_KB" -lt 716800 ]; then
  echo "ERROR: $DL sits on a filesystem with only ${DL_AVAIL_KB} KB free; the download set alone is ~602 MiB." >&2
  echo "Re-run with TMPDIR on a filesystem with at least 700 MB free, e.g.: sudo TMPDIR=/var/tmp scripts/install.sh" >&2
  exit 1
fi

fetch() { # url sha256 outfile
  curl -fsSL -o "$3" "$1"
  echo "$2  $3" | sha256sum -c - || { echo "CHECKSUM FAIL: $3"; exit 1; }
}

# --- Users (no shells, no homes) ---
for u in prometheus alertmanager blackbox nodeexp ntfy grafana backup; do
  id "$u" &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin "$u"
done

# --- Directories ---
install -d -o prometheus   -g prometheus   -m 750 /var/lib/prometheus /etc/prometheus
install -d -o alertmanager -g alertmanager -m 750 /var/lib/alertmanager /etc/alertmanager
install -d -o blackbox     -g blackbox     -m 750 /etc/blackbox
install -d -o ntfy         -g ntfy         -m 750 /var/lib/ntfy /var/cache/ntfy /etc/ntfy
install -d -o grafana      -g grafana      -m 750 /var/lib/grafana /etc/grafana
install -d -o backup       -g backup       -m 750 /var/backups/pihole /var/backups/unbound
# The backup scripts address their SSH keys by absolute path:
install -d -o backup       -g backup       -m 700 /home/backup/.ssh

# --- Binaries: fetch/verify/install (URLs per project release pages) ---
fetch "https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-${ARCH}.tar.gz" "$PROM_SHA256" "$DL/prom.tgz"
tar -xzf "$DL/prom.tgz" -C "$DL"
install -m 755 "$DL/prometheus-${PROM_VERSION}.linux-${ARCH}/prometheus" /usr/local/bin/prometheus
install -m 755 "$DL/prometheus-${PROM_VERSION}.linux-${ARCH}/promtool" /usr/local/bin/promtool

fetch "https://github.com/prometheus/alertmanager/releases/download/v${AM_VERSION}/alertmanager-${AM_VERSION}.linux-${ARCH}.tar.gz" "$AM_SHA256" "$DL/am.tgz"
tar -xzf "$DL/am.tgz" -C "$DL"
install -m 755 "$DL/alertmanager-${AM_VERSION}.linux-${ARCH}/alertmanager" /usr/local/bin/alertmanager
install -m 755 "$DL/alertmanager-${AM_VERSION}.linux-${ARCH}/amtool" /usr/local/bin/amtool

fetch "https://github.com/prometheus/blackbox_exporter/releases/download/v${BB_VERSION}/blackbox_exporter-${BB_VERSION}.linux-${ARCH}.tar.gz" "$BB_SHA256" "$DL/bb.tgz"
tar -xzf "$DL/bb.tgz" -C "$DL"
install -m 755 "$DL/blackbox_exporter-${BB_VERSION}.linux-${ARCH}/blackbox_exporter" /usr/local/bin/blackbox_exporter

fetch "https://github.com/prometheus/node_exporter/releases/download/v${NE_VERSION}/node_exporter-${NE_VERSION}.linux-${ARCH}.tar.gz" "$NE_SHA256" "$DL/ne.tgz"
tar -xzf "$DL/ne.tgz" -C "$DL"
install -m 755 "$DL/node_exporter-${NE_VERSION}.linux-${ARCH}/node_exporter" /usr/local/bin/node_exporter

fetch "https://github.com/binwiederhier/ntfy/releases/download/v${NTFY_VERSION}/ntfy_${NTFY_VERSION}_linux_${ARCH}.tar.gz" "$NTFY_SHA256" "$DL/ntfy.tgz"
tar -xzf "$DL/ntfy.tgz" -C "$DL"
install -m 755 "$DL/ntfy_${NTFY_VERSION}_linux_${ARCH}/ntfy" /usr/local/bin/ntfy

# Grafana ships as a self-contained tree; the unit runs /opt/grafana/bin/grafana.
fetch "https://dl.grafana.com/oss/release/grafana-${GRAFANA_VERSION}.linux-${ARCH}.tar.gz" "$GRAFANA_SHA256" "$DL/grafana.tgz"
rm -rf /opt/grafana
install -d -m 755 /opt/grafana
tar -xzf "$DL/grafana.tgz" -C /opt/grafana --strip-components=1
chown -R root:root /opt/grafana

# --- Backup scripts (the .service units ExecStart these paths) ---
install -m 755 scripts/pihole-backup.sh /usr/local/sbin/pihole-backup.sh
install -m 755 scripts/unbound-backup.sh /usr/local/sbin/unbound-backup.sh

# HARD GATE: refuse to enable services until all binaries are actually installed.
for b in prometheus alertmanager blackbox_exporter node_exporter ntfy; do
  [[ -x "/usr/local/bin/$b" ]] || { echo "ABORT: /usr/local/bin/$b missing — complete fetch blocks first."; exit 1; }
done
[[ -x /opt/grafana/bin/grafana ]] || { echo "ABORT: /opt/grafana/bin/grafana missing — complete the Grafana fetch block first."; exit 1; }

# --- Configs ---
install -o root -g prometheus   -m 640 configs/prometheus.yml  /etc/prometheus/
install -o root -g prometheus   -m 640 configs/alert_rules.yml /etc/prometheus/
install -o root -g alertmanager -m 640 configs/alertmanager.yml /etc/alertmanager/
install -o root -g blackbox     -m 640 configs/blackbox.yml    /etc/blackbox/
install -o root -g ntfy         -m 640 configs/ntfy-server.yml /etc/ntfy/server.yml
install -o root -g grafana      -m 640 configs/grafana.ini     /etc/grafana/

# --- Grafana admin password (created once, never overwritten) ---
# grafana.service carries a REQUIRED EnvironmentFile pointing here: without
# this file a grafana start fails closed instead of coming up on the factory
# admin/admin password. root:root 0600 — systemd reads it as root before the
# unit drops to the grafana user, so the grafana user never reads it.
if [[ ! -e /etc/grafana/grafana.env ]]; then
  if [[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
    GRAFANA_PW="$GRAFANA_ADMIN_PASSWORD"
    GRAFANA_PW_NOTE="taken from the GRAFANA_ADMIN_PASSWORD environment variable"
  else
    GRAFANA_PW="$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    GRAFANA_PW="${GRAFANA_PW:0:32}"
    GRAFANA_PW_NOTE="GENERATED — save it now; it is shown only here"
  fi
  [[ -n "$GRAFANA_PW" ]] || { echo "ABORT: Grafana admin password is empty — refusing to write it."; exit 1; }
  printf 'GF_SECURITY_ADMIN_PASSWORD=%s\n' "$GRAFANA_PW" > /etc/grafana/grafana.env
  chown root:root /etc/grafana/grafana.env
  chmod 600 /etc/grafana/grafana.env
  echo "Grafana admin password ${GRAFANA_PW_NOTE}: ${GRAFANA_PW}"
  unset GRAFANA_PW
fi

# --- Units ---
install -m 644 systemd/*.service systemd/*.timer /etc/systemd/system/
systemctl daemon-reload

# Always-on set (NOTE: grafana deliberately excluded — on-demand only):
systemctl enable --now node_exporter blackbox_exporter prometheus alertmanager ntfy
systemctl enable --now pihole-backup.timer unbound-backup.timer
