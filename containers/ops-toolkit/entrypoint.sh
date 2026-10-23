#!/usr/bin/env bash
#
# NAME: entrypoint.sh (containers/ops-toolkit)
# WHAT: Prepares the toolkit's runtime directories, then execs the
#       container command (cron -f by default). Passing a job script
#       name runs that one job once instead, e.g.
#         docker compose run --rm ops-toolkit /usr/local/sbin/sys-health.sh
# WHY:  The scripts expect /var/log/ops and /var/lib/ops-toolkit to
#       exist (common.sh's load_config also creates them, but the log
#       directory must exist before cron's first redirect).
#
set -euo pipefail

install -d -m 0755 /var/log/ops /var/lib/ops-toolkit

exec "$@"
