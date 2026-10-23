#!/usr/bin/env bash
#
# NAME: firewall-audit.sh (containers/firewall-audit)
# WHAT: Container form of the fleet firewall audit (bash:
#       scripts/network/firewall_audit.sh; Ansible:
#       ansible/playbooks/firewall/firewall_audit.yml). Runs the bash
#       audit's thirteen collection sections against the network
#       namespace and firewall it can see, and flags a host with no
#       active firewall.
# HOW:  firewall-audit.sh [--output FILE]
#       For the output to describe the HOST, the container must share
#       the host's network namespace (the shipped compose does:
#       network_mode: host) and hold CAP_NET_ADMIN so nft/iptables can
#       read the host rulesets — both are read-only queries. Without
#       host networking the report describes the container's own
#       (normally empty) namespace, which the Findings section will
#       flag as no-active-firewall; README.md explains the model and
#       the optional D-Bus mount that lets firewall-cmd query the
#       host's firewalld.
#
set -uo pipefail

OUTPUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --output) OUTPUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

emit() { printf '%s\n' "$*"; }

collect() {
  emit "Starting firewall and port audit..."
  emit "Timestamp: $(date)"
  emit "========================================="
  emit "========== $(hostname) =========="
  emit "Timestamp: $(date)"
  emit ""

  emit "--- SELinux Status ---"
  getenforce 2>/dev/null || echo "SELinux not available"
  emit ""

  emit "--- FirewallD Status ---"
  systemctl is-active firewalld 2>/dev/null && firewall-cmd --state 2>/dev/null || echo "FirewallD not active or not installed"
  emit ""

  emit "--- Active Zones & Services ---"
  firewall-cmd --get-active-zones 2>/dev/null && firewall-cmd --list-services 2>/dev/null || echo "No active zones/services"
  emit ""

  emit "--- Masquerading & Port Forwarding ---"
  firewall-cmd --query-masquerade 2>/dev/null && firewall-cmd --list-forward-ports 2>/dev/null || echo "No masquerading or port forwarding"
  emit ""

  emit "--- iptables Rules ---"
  iptables -L -n -v 2>/dev/null || echo "iptables not available"
  emit ""

  emit "--- nftables Rules ---"
  nft list ruleset 2>/dev/null || echo "nftables not in use"
  emit ""

  emit "--- Open Ports (ss) ---"
  ss -tuln 2>/dev/null || netstat -tuln 2>/dev/null || echo "ss/netstat not available"
  emit ""

  emit "--- PID to Command Mapping for Open Ports ---"
  ss -tulnp 2>/dev/null | awk "NR>1" | while read -r line; do
    pid=$(echo "$line" | grep -oP "pid=\K[0-9]+")
    if [ -n "$pid" ]; then
      cmd=$(ps -p "$pid" -o cmd=)
      echo "PID: $pid - Command: $cmd"
    fi
  done || echo "No PID to command mapping available"
  emit ""

  emit "--- Listening Services (lsof) ---"
  lsof -i -P -n 2>/dev/null | grep LISTEN || echo "lsof not available or no services listening"
  emit ""

  emit "--- Non-localhost Bound Ports ---"
  ss -tuln 2>/dev/null | grep -v "127.0.0.1" || echo "No external bindings found"
  emit ""

  emit "--- Installed Firewall Packages ---"
  if command -v rpm >/dev/null 2>&1; then
    rpm -qa | grep -E "firewalld|iptables|nftables" || true
  else
    dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -E "firewalld|iptables|nftables|ufw" || true
  fi
  emit ""

  emit "--- Recent Firewall Changes ---"
  find /etc/firewalld /etc/sysconfig/iptables -type f -exec ls -l {} \; 2>/dev/null || true
  emit ""

  emit "--- FirewallD Logs (last 7 days) ---"
  journalctl -u firewalld --since "7 days ago" 2>/dev/null || echo "No recent logs found"
  emit ""

  emit "--- Findings ---"
  fw_state="$(firewall-cmd --state 2>/dev/null || true)"
  nft_out="$(nft list ruleset 2>/dev/null || true)"
  ipt_rules="$(iptables -S 2>/dev/null | grep -c '^-A' || true)"
  active=0
  [ "$fw_state" = "running" ] && active=1
  [ -n "$nft_out" ] && active=1
  [ "${ipt_rules:-0}" -gt 0 ] 2>/dev/null && active=1
  if [ "$active" -eq 0 ]; then
    emit "FLAG no-active-firewall: firewalld is not running and no nftables ruleset or iptables chains were found"
  fi
  ss -tuln 2>/dev/null | grep -v "127.0.0.1" | grep -v "^Netid" | while read -r l; do
    [ -n "$l" ] && emit "REVIEW non-localhost listener: $l"
  done
  [ "$active" -eq 1 ] && emit "(firewall active; listeners above are for review)"

  emit ""
  emit "Firewall audit complete."
}

if [ -n "$OUTPUT" ]; then
  collect | tee "$OUTPUT"
  chmod 600 "$OUTPUT"
else
  collect
fi
