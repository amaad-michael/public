#!/usr/bin/env bash
# neo1 success criteria — all checks must pass before calling this deployed.
set -u
pass=0; fail=0
chk() { if eval "$2" &>/dev/null; then echo "PASS  $1"; ((pass++)); else echo "FAIL  $1"; ((fail++)); fi; }

chk "prometheus active"            "systemctl is-active prometheus"
chk "alertmanager active"          "systemctl is-active alertmanager"
chk "blackbox active"              "systemctl is-active blackbox_exporter"
chk "node_exporter active"         "systemctl is-active node_exporter"
chk "ntfy active"                  "systemctl is-active ntfy"
chk "grafana NOT enabled"          "! systemctl is-enabled grafana"
chk "prom healthy"                 "curl -sf http://127.0.0.1:9091/-/healthy"
chk "am healthy"                   "curl -sf http://127.0.0.1:9093/-/healthy"
chk "no REPLACE_ME left"           "! grep -rq REPLACE_ME /etc/prometheus /etc/blackbox"
chk "all scrape targets up"        "[ \$(curl -sf 'http://127.0.0.1:9091/api/v1/query?query=up==0' | grep -c instance) -eq 0 ]"
chk "am->ntfy token present"       "test -s /etc/alertmanager/ntfy.token"
chk "9093 loopback only"           "! ss -tlnp | grep ':9093' | grep -v 127.0.0.1"
chk "9115 loopback only"           "! ss -tlnp | grep ':9115' | grep -v 127.0.0.1"
chk "steady-state RAM < 420MB"     "[ \$(free -m | awk '/^Mem:/{print \$3}') -lt 420 ]"

echo; echo "== $pass passed / $fail failed =="
echo "FINAL GATE (manual): fire a test alert and confirm phone delivery:"
echo "  curl -H 'Authorization: Bearer \$(cat /etc/alertmanager/ntfy.token)' -d test http://127.0.0.1:8081/alerts"
exit $fail
