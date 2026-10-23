#!/usr/bin/env bash
# neo1 UFW policy — default deny, explicit LAN allowances only.
set -euo pipefail

LAN="192.168.0.0/24"   # access policy: entire subnet (owner decision, 2026-07)

ufw default deny incoming
ufw default allow outgoing

# SSH — LAN
ufw allow from "$LAN" to any port 22 proto tcp comment 'ssh lan'

# Prometheus UI/API — LAN
ufw allow from "$LAN" to any port 9091 proto tcp comment 'prometheus ui'

# node_exporter — LAN
ufw allow from "$LAN" to any port 9100 proto tcp comment 'node_exporter'

# ntfy — LAN; tighten to tailnet range post-migration
ufw allow from "$LAN" to any port 8081 proto tcp comment 'ntfy'

# Grafana (on-demand sessions) — LAN
ufw allow from "$LAN" to any port 3002 proto tcp comment 'grafana on-demand'

# NOT opened: 9093 (alertmanager) and 9115 (blackbox) — loopback-bound by unit config.
ufw --force enable
ufw status verbose
