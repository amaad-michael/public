#!/usr/bin/env bash
#
# NAME: smart-harvest.sh
# WHAT: Bash form of the SMART harvest: collects SMART data from
#       every physical disk on this host and writes one JSON report
#       per host, with the same fields as the Ansible form
#       (ansible/playbooks/healthchecks/smart-harvest-v1.0.yml):
#       host, collected_at, and per-drive device, rc, supported,
#       health_passed, model, serial, temperature_c,
#       power_on_hours, plus the full smartctl JSON.
# WHY:  Scheduled drive-health harvesting for the homelab, runnable
#       locally without Ansible. Collection is read-only and
#       idempotent: re-running overwrites the same report file and
#       never duplicates data, and drives without SMART support
#       (SD cards, some USB enclosures) are captured as unsupported
#       rather than failing the run. The Docker form is
#       containers/health-smart/.
# HOW:  ./smart-harvest.sh [--output-dir DIR] [--keep-history]
#         [--extra-args "-d sat"] [--] [/dev/sda ...]
#       With no drive arguments, disks are auto-discovered with
#       lsblk, exactly as the Ansible form discovers them.
#
# Options:
#   --output-dir DIR   Report directory (default: ./smart-data)
#   --keep-history     Also keep a dated copy under
#                      <output-dir>/history/
#   --extra-args ARGS  Extra smartctl arguments, e.g. "-d sat" for
#                      drives behind USB enclosures
#   -h, --help         Show this help
#
# Exit codes: 0 harvest complete (unsupported drives included),
# 1 a prerequisite is missing, 2 usage error.
#
set -euo pipefail

OUTPUT_DIR="./smart-data"
KEEP_HISTORY=0
EXTRA_ARGS=""
DRIVES=()

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

usage() {
    sed -n '2,/^#$/p' "$0" | sed 's/^# \{0,1\}//'
}

while (($#)); do
    case "$1" in
        --output-dir)
            (($# >= 2)) || { printf 'error: --output-dir requires a value\n' >&2; exit 2; }
            OUTPUT_DIR="$2"; shift ;;
        --keep-history) KEEP_HISTORY=1 ;;
        --extra-args)
            (($# >= 2)) || { printf 'error: --extra-args requires a value\n' >&2; exit 2; }
            EXTRA_ARGS="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; while (($#)); do DRIVES+=("$1"); shift; done; break ;;
        -*) printf 'error: unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
        *) DRIVES+=("$1") ;;
    esac
    shift
done

# --- Prerequisites (fail loudly, change nothing) ------------------------------
command -v smartctl >/dev/null 2>&1 \
    || die "smartctl not found — install smartmontools first"
command -v python3 >/dev/null 2>&1 \
    || die "python3 not found — needed to assemble the JSON report"
if [[ $EUID -ne 0 ]]; then
    printf 'warning: not running as root; smartctl may be denied device access and drives will report as unsupported\n' >&2
fi

# --- Drive discovery (same rule as the Ansible form: lsblk type=disk) --------
if ((${#DRIVES[@]} == 0)); then
    command -v lsblk >/dev/null 2>&1 \
        || die "lsblk not found — needed for drive auto-discovery (or pass drives explicitly)"
    mapfile -t DRIVES < <(lsblk -d -n -o NAME,TYPE | awk '$2 == "disk" {print "/dev/" $1}')
fi
info "drives (${#DRIVES[@]}): ${DRIVES[*]:-none}"

# --- Collect ---------------------------------------------------------------------
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUTPUT_DIR"
HOST_NAME=$(hostname)
COLLECTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

i=0
for dev in "${DRIVES[@]}"; do
    raw="$WORK/raw-$i.json"
    # smartctl exit status is a bitmask; like the Ansible form, every
    # outcome is captured, never fatal. Word splitting of $EXTRA_ARGS
    # is intentional (it is an argument list, e.g. "-d sat").
    # shellcheck disable=SC2086
    timeout 60 smartctl --json --all $EXTRA_ARGS "$dev" > "$raw" 2>/dev/null && rc=0 || rc=$?
    printf '%s' "$rc" > "$WORK/raw-$i.rc"
    printf '%s' "$dev" > "$WORK/raw-$i.dev"
    i=$((i + 1))
done

# --- Assemble the per-host report (field-for-field the Ansible form) -------------
python3 - "$WORK" "$i" "$HOST_NAME" "$COLLECTED_AT" "$OUTPUT_DIR/$HOST_NAME.json" <<'PYEOF'
import json
import pathlib
import sys

work, count, host, collected_at, out_path = (
    pathlib.Path(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5])

drives = []
for i in range(count):
    device = (work / f"raw-{i}.dev").read_text().strip()
    rc = int((work / f"raw-{i}.rc").read_text().strip())
    text = (work / f"raw-{i}.json").read_text(errors="replace").strip()
    raw = {}
    if text.startswith("{"):
        try:
            raw = json.loads(text)
        except json.JSONDecodeError:
            raw = {}
    dev_info = raw.get("device") or {}
    drives.append({
        "device": device,
        "rc": rc,
        "supported": (raw.get("smart_support") or {}).get("available", False),
        "health_passed": (raw.get("smart_status") or {}).get("passed", "n/a"),
        "model": raw.get("model_name") or dev_info.get("name") or "unknown",
        # smartctl puts the serial at the top level; the Ansible form
        # reads device.serial_number (absent in current smartctl
        # JSON), so prefer the top-level value and fall back to it.
        "serial": raw.get("serial_number") or dev_info.get("serial_number") or "unknown",
        "temperature_c": (raw.get("temperature") or {}).get("current", "n/a"),
        "power_on_hours": (raw.get("power_on_time") or {}).get("hours", "n/a"),
        "full": raw,
    })

report = {"host": host, "collected_at": collected_at, "drives": drives}
pathlib.Path(out_path).write_text(json.dumps(report, indent=2) + "\n")
print(f"wrote {out_path} ({len(drives)} drive(s))")
PYEOF

if [[ $KEEP_HISTORY -eq 1 ]]; then
    mkdir -p "$OUTPUT_DIR/history"
    cp "$OUTPUT_DIR/$HOST_NAME.json" "$OUTPUT_DIR/history/$HOST_NAME-$(date +%s).json"
    info "history copy kept under $OUTPUT_DIR/history/"
fi
info "harvest complete"
