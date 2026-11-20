#!/usr/bin/env bash
# neo1 v3.0 (docker) success criteria — all checks must pass.
set -u
pass=0; fail=0
chk() { if eval "$2" &>/dev/null; then echo "PASS  $1"; ((pass++)); else echo "FAIL  $1"; ((fail++)); fi; }

for c in prometheus alertmanager blackbox node-exporter ntfy backup-runner; do
  chk "neo1-$c running" "docker ps --filter name=neo1-$c --filter status=running --format x | grep -q x"
done
for c in prometheus alertmanager blackbox ntfy; do
  chk "neo1-$c healthy" "docker inspect -f '{{.State.Health.Status}}' neo1-$c | grep -q healthy"
done
chk "grafana NOT running (profile-gated)"  "! docker ps --filter name=neo1-grafana --format x | grep -q x"
chk "prom healthy endpoint"    "curl -sf http://127.0.0.1:9091/-/healthy"
chk "am healthy endpoint"      "curl -sf http://127.0.0.1:9093/-/healthy"
chk "no REPLACE_ME left"       "! grep -rq REPLACE_ME configs/"
chk "all scrape targets up"    "[ \$(curl -sf 'http://127.0.0.1:9091/api/v1/query?query=up==0' | grep -c instance) -eq 0 ]"
chk "ntfy token present"       "test -s secrets/ntfy.token"
chk "9093 loopback only"       "! ss -tlnp | grep ':9093' | grep -v 127.0.0.1"
chk "9115 loopback only"       "! ss -tlnp | grep ':9115' | grep -v 127.0.0.1"
chk "no docker-published ports (host-net design)" "! docker ps --format '{{.Ports}}' | grep -q '->'"
chk "docker.sock not mounted anywhere" "! docker ps -q | xargs -r -n1 docker inspect -f '{{range .Mounts}}{{.Source}}{{end}}' | grep -q docker.sock"
chk "steady-state RAM < 460MB" "[ \$(free -m | awk '/^Mem:/{print \$3}') -lt 460 ]"

echo; echo "== $pass passed / $fail failed =="
echo "FINAL GATES (manual):"
echo "  1. Test alert -> phone:  curl -H \"Authorization: Bearer \$(cat secrets/ntfy.token)\" -d test http://127.0.0.1:8081/alerts"
echo "  2. Restore-test one backup from each script after first nightly run."
exit $fail
