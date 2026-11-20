#!/usr/bin/env bash
# gpu-bench v1.0.4 — multi-backend GPU benchmark and stress harness for Linux.
#
# Backends: furmark (primary), occt, superposition, gravitymark, glmark2, vkmark.
# Every run is wrapped in the same envelope: GPU inventory, live telemetry
# sampling from the amdgpu sysfs, a run directory of artifacts, score
# extraction where the backend emits one, and an HTML dashboard regenerated
# from all run artifacts.
#
# FurMark invocation uses only the flags corroborated by Geeks3D's own
# release notes: -demo furmark-gl|furmark-vk, --p<WIDTHxHEIGHT> presets,
# -furmark-vram-test-gb N. Stress duration is bounded by timeout(1), not by
# an unverified FurMark flag. OCCT, Superposition, and GravityMark run
# through a configurable command template (see `gpu-bench check`), because
# their Linux CLI surfaces should be wired from the installed binary's own
# --help output, captured by the check verb.
#
# Environment:
#   GPU_BENCH_HOME     home for results + dashboard (default: the script’s own folder)
#   GPU_BENCH_SYSFS    sysfs root override (testing; default /sys)
#   FURMARK_BIN        explicit FurMark command (else flatpak, else PATH)
#   OCCT_BIN, SUPERPOSITION_BIN, GRAVITYMARK_BIN   explicit backend commands
#   GPU_BENCH_<BACKEND>_ARGS   extra args appended for template backends
set -u

VERSION="1.0.4"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_HOME="${GPU_BENCH_HOME:-$SCRIPT_DIR}"
RESULTS_DIR="$BENCH_HOME/results"
DASHBOARD="$BENCH_HOME/dashboard.html"
SYSFS="${GPU_BENCH_SYSFS:-/sys}"
DASHBOARD_PY="$SCRIPT_DIR/gpu_bench_dashboard.py"
SAMPLE_SECONDS=2

die() { echo "gpu-bench: $*" >&2; exit 2; }
info() { echo "gpu-bench: $*"; }
to_upper() { local s="$1"; printf '%s' "${s^^}"; }
first_glob() { local g; for g in $1; do [ -e "$g" ] && { printf '%s' "$g"; return 0; }; done; return 1; }

usage() {
  cat <<'EOF'
gpu-bench v1.0.4 — GPU benchmark and stress harness (Linux, AMD first)

Usage:
  gpu-bench check [--probe]
  gpu-bench bench <backend> [--api gl|vk] [--preset 1080|1440|uw1440|2160]
  gpu-bench stress <backend> [--api gl|vk] [--minutes N]
  gpu-bench vram [--gb N] [--minutes N]
  gpu-bench record [--run <run-id>] [--score N] [--fps N]
  gpu-bench dashboard
  gpu-bench latest

Backends: furmark, occt, superposition, gravitymark, glmark2, vkmark
  furmark       presets are timed 60 s benchmarks; stress runs until the
                minute bound; vram uses FurMark's VRAM test demo.
  occt          error-detected stability (template launch; see check).
  superposition game-like OpenGL score (template launch; see check).
  gravitymark   modern cross-API score (template launch; see check).
  glmark2       quick OpenGL sanity score (not a stress test).
  vkmark        quick Vulkan sanity score (not a stress test).

Scores compare only within a lane: same backend, API, preset, and driver
stack. A Mesa score and a Windows-driver score measure different drivers.

FurMark on the Flatpak build is click-through: the command line opens the
GUI configured, a human clicks the BENCHMARK Preset button (only the
preset matching the display's native resolution is armed), and the run
ends when the window closes. FurMark prints no score to the terminal and
writes no local score file, so read the score off its window and file it
with: gpu-bench record --score N --fps N
EOF
}

# ---------------------------------------------------------------- GPU inventory
list_cards() {
  local d b
  for d in "$SYSFS"/class/drm/card[0-9]*; do
    [ -d "$d/device" ] || continue
    b="$(basename "$d")"
    case "$b" in card*[!0-9]*) continue ;; esac
    echo "$b"
  done
}

card_vendor() { cat "$SYSFS/class/drm/$1/device/vendor" 2>/dev/null || echo "?"; }
card_device() { cat "$SYSFS/class/drm/$1/device/device" 2>/dev/null || echo "?"; }

gpu_name() {
  # Best effort: lspci by slot, else vendor/device ids.
  local card="$1" slot name
  slot="$(basename "$(readlink -f "$SYSFS/class/drm/$card/device" 2>/dev/null)" 2>/dev/null)"
  if command -v lspci >/dev/null 2>&1 && [ -n "$slot" ]; then
    name="$(lspci -s "$slot" 2>/dev/null | sed 's/^[^:]*: [^:]*: //')"
    [ -n "$name" ] && { echo "$name"; return; }
  fi
  echo "GPU vendor=$(card_vendor "$card") device=$(card_device "$card")"
}

mesa_version() {
  if command -v glxinfo >/dev/null 2>&1; then
    glxinfo 2>/dev/null | grep -m1 'OpenGL version string' | sed 's/.*: //'
  else
    echo "unknown (glxinfo absent)"
  fi
}

# ------------------------------------------------------------------- telemetry
# One sample row for one card: epoch,temp_c,power_w,fan_rpm,busy_pct,vram_mb,sclk_mhz
sample_card() {
  local card="$1" dev hw t p f busy used sclk
  dev="$SYSFS/class/drm/$card/device"
  hw="$(first_glob "$dev/hwmon/hwmon*" || true)"
  t=""; p=""; f=""
  if [ -n "$hw" ]; then
    [ -r "$hw/temp1_input" ] && t="$(awk '{printf "%.1f", $1/1000}' "$hw/temp1_input" 2>/dev/null)"
    [ -r "$hw/power1_average" ] && p="$(awk '{printf "%.1f", $1/1000000}' "$hw/power1_average" 2>/dev/null)"
    [ -r "$hw/fan1_input" ] && f="$(cat "$hw/fan1_input" 2>/dev/null)"
  fi
  # A live GPU never reports a true 0.0 C edge temp or 0.0 W board power;
  # a zero here is a raced or failed read, so record it as missing.
  [ "$t" = "0.0" ] && t=""
  [ "$p" = "0.0" ] && p=""
  busy="$(cat "$dev/gpu_busy_percent" 2>/dev/null || echo "")"
  used=""
  [ -r "$dev/mem_info_vram_used" ] && used="$(awk '{printf "%.0f", $1/1048576}' "$dev/mem_info_vram_used" 2>/dev/null)"
  sclk=""
  if [ -r "$dev/pp_dpm_sclk" ]; then
    sclk="$(grep '\*' "$dev/pp_dpm_sclk" 2>/dev/null | grep -o '[0-9]\+' | tail -1)"
  fi
  echo "$(date +%s),${t:-},${p:-},${f:-},${busy:-},${used:-},${sclk:-}"
}

sampler_loop() {
  local card="$1" out="$2"
  echo "epoch,temp_c,power_w,fan_rpm,busy_pct,vram_mb,sclk_mhz" > "$out"
  while :; do
    sample_card "$card" >> "$out"
    sleep "$SAMPLE_SECONDS"
  done
}

# ------------------------------------------------------------------- backends
resolve_furmark() {
  if [ -n "${FURMARK_BIN:-}" ]; then echo "$FURMARK_BIN"; return 0; fi
  if command -v flatpak >/dev/null 2>&1 && flatpak info com.geeks3d.furmark >/dev/null 2>&1; then
    echo "flatpak run com.geeks3d.furmark"; return 0
  fi
  if command -v furmark >/dev/null 2>&1; then command -v furmark; return 0; fi
  return 1
}

resolve_simple() {
  # $1 = env override value, $2 = PATH name
  if [ -n "$1" ]; then echo "$1"; return 0; fi
  if command -v "$2" >/dev/null 2>&1; then command -v "$2"; return 0; fi
  return 1
}

preset_dims() {
  case "$1" in
    1080) echo "1920x1080" ;;
    1440) echo "2560x1440" ;;
    uw1440) echo "3440x1440" ;;
    2160) echo "3840x2160" ;;
    *) return 1 ;;
  esac
}

# ------------------------------------------------------------- score extraction
extract_score() {
  # $1 backend, $2 log file, $3 output score.env
  local backend="$1" log="$2" out="$3" score="" fps=""
  : > "$out"
  case "$backend" in
    furmark)
      score="$(grep -aoiE 'SCORE[^0-9]{0,12}[0-9]+' "$log" | grep -o '[0-9]\+' | tail -1)"
      fps="$(grep -aoiE 'FPS[^0-9]{0,12}[0-9]+' "$log" | grep -o '[0-9]\+' | tail -1)"
      ;;
    glmark2|vkmark)
      score="$(grep -aE "$backend Score:" "$log" | grep -o '[0-9]\+' | tail -1)"
      ;;
    *)
      score="$(grep -aoiE 'score[^0-9]{0,12}[0-9]+' "$log" | grep -o '[0-9]\+' | tail -1)"
      fps="$(grep -aoiE 'fps[^0-9]{0,12}[0-9]+' "$log" | grep -o '[0-9]\+' | tail -1)"
      ;;
  esac
  if [ -n "$score" ]; then
    echo "score=$score" >> "$out"
    echo "score_source=parsed" >> "$out"
  else
    echo "score_source=unparsed" >> "$out"
  fi
  [ -n "$fps" ] && echo "fps=$fps" >> "$out"
}

# ------------------------------------------------------------------ run envelope
# run_envelope <backend> <mode> <api> <preset-label> <timeout-seconds> <cmd...>
run_envelope() {
  local backend="$1" mode="$2" api="$3" preset="$4" tmo="$5"; shift 5
  local card host ts run_id run_dir
  card="$(list_cards | head -1)"
  [ -n "$card" ] || die "no DRM card found under $SYSFS/class/drm"
  host="$(hostname -s 2>/dev/null || echo unknown)"
  ts="$(date +%Y%m%d-%H%M%S)"
  run_id="$ts-$host-$backend-$mode"
  run_dir="$RESULTS_DIR/$run_id"
  mkdir -p "$run_dir"

  info "run $run_id on $card ($(gpu_name "$card"))"
  info "command: $*"

  sampler_loop "$card" "$run_dir/telemetry.csv" &
  local sampler_pid=$!
  local start=$SECONDS rc=0
  ( cd "$run_dir" && timeout --signal=INT "${tmo}s" "$@" ) > "$run_dir/backend.log" 2>&1 || rc=$?
  local elapsed=$((SECONDS - start))
  kill "$sampler_pid" 2>/dev/null; wait "$sampler_pid" 2>/dev/null

  extract_score "$backend" "$run_dir/backend.log" "$run_dir/score.env"

  python3 - "$run_dir" "$backend" "$mode" "$api" "$preset" "$rc" "$elapsed" <<'PYEOF'
import json, os, platform, subprocess, sys
run_dir, backend, mode, api, preset, rc, elapsed = sys.argv[1:8]
def sh(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout.strip()
    except Exception:
        return ""
meta = {
    "run_id": os.path.basename(run_dir),
    "host": platform.node(),
    "backend": backend,
    "mode": mode,
    "api": api,
    "preset": preset,
    "exit_code": int(rc),
    "elapsed_s": int(elapsed),
    "started": sh(["date", "-Is"]),
    "kernel": platform.release(),
    "os": sh(["bash", "-c", ". /etc/os-release 2>/dev/null; echo $PRETTY_NAME"]),
}
score = {}
try:
    for line in open(os.path.join(run_dir, "score.env")):
        if "=" in line:
            k, v = line.strip().split("=", 1)
            score[k] = v
except OSError:
    pass
meta.update(score)
# telemetry summary
tmax = pmax = None
try:
    rows = [l.split(",") for l in open(os.path.join(run_dir, "telemetry.csv")).read().splitlines()[1:] if l]
    temps = [float(r[1]) for r in rows if len(r) > 1 and r[1]]
    powers = [float(r[2]) for r in rows if len(r) > 2 and r[2]]
    if temps: tmax = max(temps)
    if powers: pmax = max(powers)
except OSError:
    pass
meta["temp_max_c"] = tmax
meta["power_max_w"] = pmax
with open(os.path.join(run_dir, "meta.json"), "w") as f:
    json.dump(meta, f, indent=1, sort_keys=True)
print(f"gpu-bench: artifacts in {run_dir}")
if "score" in meta:
    print(f"gpu-bench: score {meta['score']}" + (f" fps {meta['fps']}" if "fps" in meta else ""))
else:
    print("gpu-bench: no score parsed (raw backend log kept); telemetry summary: "
          f"temp_max={tmax} power_max={pmax}")
PYEOF
  regenerate_dashboard || true
}

regenerate_dashboard() {
  if [ -f "$DASHBOARD_PY" ] && command -v python3 >/dev/null 2>&1; then
    if python3 "$DASHBOARD_PY" "$RESULTS_DIR" "$DASHBOARD" >/dev/null 2>&1; then
      info "dashboard regenerated: $DASHBOARD"
    else
      info "dashboard generation failed (runs are kept)"
    fi
  fi
}

# ----------------------------------------------------------------------- verbs
do_check() {
  local probe=0
  [ "${1:-}" = "--probe" ] && probe=1
  echo "gpu-bench $VERSION — host $(hostname -s), kernel $(uname -r)"
  echo "Mesa/OpenGL: $(mesa_version)"
  local c
  for c in $(list_cards); do
    echo "GPU $c: $(gpu_name "$c") [vendor $(card_vendor "$c") device $(card_device "$c")]"
    local hw; hw="$(first_glob "$SYSFS/class/drm/$c/device/hwmon/hwmon*" || true)"
    if [ -n "$hw" ]; then
      echo "  telemetry: temp=$([ -r "$hw/temp1_input" ] && echo yes || echo no) power=$([ -r "$hw/power1_average" ] && echo yes || echo no) fan=$([ -r "$hw/fan1_input" ] && echo yes || echo no)"
    else
      echo "  telemetry: no hwmon directory found"
    fi
  done
  mkdir -p "$BENCH_HOME/probe"
  backend_line furmark "$(resolve_furmark || true)" "flatpak install flathub com.geeks3d.furmark"
  backend_line occt "$(resolve_simple "${OCCT_BIN:-}" OCCT || true)" "download the Linux build from ocbase.com, then set OCCT_BIN"
  backend_line superposition "$(resolve_simple "${SUPERPOSITION_BIN:-}" Superposition || true)" "download the .run from benchmark.unigine.com, then set SUPERPOSITION_BIN"
  backend_line gravitymark "$(resolve_simple "${GRAVITYMARK_BIN:-}" GravityMark || true)" "download from gravitymark.tellusim.com, then set GRAVITYMARK_BIN"
  backend_line glmark2 "$(resolve_simple "" glmark2 || true)" "sudo dnf install glmark2"
  backend_line vkmark "$(resolve_simple "" vkmark || true)" "sudo dnf install vkmark"
  if [ "$probe" = 1 ]; then
    local b cmd
    echo "probe: furmark skipped (this build has no text help; --help opens its GUI)"
    for b in occt superposition gravitymark; do
      case "$b" in
        occt) cmd="$(resolve_simple "${OCCT_BIN:-}" OCCT || true)" ;;
        superposition) cmd="$(resolve_simple "${SUPERPOSITION_BIN:-}" Superposition || true)" ;;
        gravitymark) cmd="$(resolve_simple "${GRAVITYMARK_BIN:-}" GravityMark || true)" ;;
      esac
      [ -n "$cmd" ] || continue
      # $cmd is a command line (program plus any fixed prefix, e.g. flatpak run ...): word splitting is intended.
      # shellcheck disable=SC2086
      timeout 10 $cmd --help > "$BENCH_HOME/probe/$b-help.txt" 2>&1 || true
      if [ "$b" = furmark ]; then
        echo "probe: furmark help captured to $BENCH_HOME/probe/$b-help.txt (the binary's own flag reference)"
      else
        echo "probe: $b help captured to $BENCH_HOME/probe/$b-help.txt (wire GPU_BENCH_$(to_upper "$b")_ARGS from it)"
      fi
    done
  fi
}

backend_line() {
  # $1 name, $2 resolved cmd (may be empty), $3 install hint
  if [ -n "$2" ]; then echo "backend $1: $2"; else echo "backend $1: NOT FOUND — $3"; fi
}

parse_opts() {
  API="gl"; PRESET="1080"; MINUTES=10; GB=10
  while [ $# -gt 0 ]; do
    case "$1" in
      --api) API="$2"; shift 2 ;;
      --preset) PRESET="$2"; shift 2 ;;
      --minutes) MINUTES="$2"; shift 2 ;;
      --gb) GB="$2"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  case "$API" in gl|vk) ;; *) die "--api must be gl or vk" ;; esac
}

template_cmd() {
  # $1 backend; echoes the launch command or dies with the install hint
  local backend="$1" cmd="" extra=""
  case "$backend" in
    occt) cmd="$(resolve_simple "${OCCT_BIN:-}" OCCT || true)"; extra="${GPU_BENCH_OCCT_ARGS:-}" ;;
    superposition) cmd="$(resolve_simple "${SUPERPOSITION_BIN:-}" Superposition || true)"; extra="${GPU_BENCH_SUPERPOSITION_ARGS:-}" ;;
    gravitymark) cmd="$(resolve_simple "${GRAVITYMARK_BIN:-}" GravityMark || true)"; extra="${GPU_BENCH_GRAVITYMARK_ARGS:-}" ;;
  esac
  [ -n "$cmd" ] || die "backend $backend not found (run: gpu-bench check)"
  echo "$cmd $extra"
}

do_bench() {
  local backend="${1:-}"; shift || true
  [ -n "$backend" ] || die "bench needs a backend"
  parse_opts "$@"
  local dims; dims="$(preset_dims "$PRESET")" || die "unknown preset: $PRESET"
  case "$backend" in
    furmark)
      local fm; fm="$(resolve_furmark)" || die "furmark not found (run: gpu-bench check)"
      info "FurMark opens configured, not started: click BENCHMARK Preset $dims in its window (only the native-resolution preset is armed on this build), let it run, then close the window to finalize this run"
      # shellcheck disable=SC2086
      run_envelope furmark bench "$API" "$PRESET" 240 $fm -demo "furmark-$API" "--p$dims"
      ;;
    glmark2)
      local g; g="$(resolve_simple "" glmark2)" || die "glmark2 not found (run: gpu-bench check)"
      run_envelope glmark2 bench "$API" "$PRESET" 1800 "$g" --size "$dims"
      ;;
    vkmark)
      local v; v="$(resolve_simple "" vkmark)" || die "vkmark not found (run: gpu-bench check)"
      run_envelope vkmark bench vk "$PRESET" 1800 "$v" --size "$dims"
      ;;
    occt|superposition|gravitymark)
      local cmd; cmd="$(template_cmd "$backend")"
      info "template launch: set GPU_BENCH_$(to_upper "$backend")_ARGS from the binary's --help (see gpu-bench check --probe); the envelope records telemetry for up to $MINUTES min or until the program exits"
      # shellcheck disable=SC2086
      run_envelope "$backend" bench "$API" "$PRESET" $((MINUTES * 60)) $cmd
      ;;
    *) die "unknown backend: $backend" ;;
  esac
}

do_stress() {
  local backend="${1:-}"; shift || true
  [ -n "$backend" ] || die "stress needs a backend"
  parse_opts "$@"
  case "$backend" in
    furmark)
      local fm; fm="$(resolve_furmark)" || die "furmark not found (run: gpu-bench check)"
      info "FurMark opens configured, not started: click RUN TEST in its window, and close the window when the stress session is done (envelope bound: $MINUTES min)"
      # shellcheck disable=SC2086
      run_envelope furmark stress "$API" "default" $((MINUTES * 60 + 30)) $fm -demo "furmark-$API"
      ;;
    glmark2)
      local g; g="$(resolve_simple "" glmark2)" || die "glmark2 not found (run: gpu-bench check)"
      run_envelope glmark2 stress "$API" "default" $((MINUTES * 60 + 30)) "$g" --run-forever
      ;;
    vkmark)
      local v; v="$(resolve_simple "" vkmark)" || die "vkmark not found (run: gpu-bench check)"
      run_envelope vkmark stress vk "default" $((MINUTES * 60 + 30)) bash -c "while :; do $v >/dev/null 2>&1; done"
      ;;
    occt|superposition|gravitymark)
      local cmd; cmd="$(template_cmd "$backend")"
      # shellcheck disable=SC2086
      run_envelope "$backend" stress "$API" "default" $((MINUTES * 60 + 30)) $cmd
      ;;
    *) die "unknown backend: $backend" ;;
  esac
}

do_vram() {
  parse_opts "$@"
  local fm; fm="$(resolve_furmark)" || die "furmark not found (run: gpu-bench check)"
  # shellcheck disable=SC2086
  run_envelope furmark vram gl "${GB}gb" $((MINUTES * 60 + 30)) $fm -demo furmark-gl "-furmark-vram-test-gb" "$GB"
}

do_record() {
  local run_id="" score="" fps=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --run) run_id="$2"; shift 2 ;;
      --score) score="$2"; shift 2 ;;
      --fps) fps="$2"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -n "$score" ] || [ -n "$fps" ] || die "record needs --score and/or --fps"
  local run_dir=""
  if [ -n "$run_id" ]; then
    run_dir="$RESULTS_DIR/$run_id"
  else
    local d
    for d in "$RESULTS_DIR"/*/; do [ -d "$d" ] && run_dir="${d%/}"; done
  fi
  if [ -z "$run_dir" ] || [ ! -f "$run_dir/meta.json" ]; then die "no run found to record against"; fi
  {
    [ -n "$score" ] && echo "score=$score"
    echo "score_source=manual"
    [ -n "$fps" ] && echo "fps=$fps"
  } > "$run_dir/score.env"
  python3 - "$run_dir/meta.json" "$score" "$fps" <<'PYEOF'
import json, sys
path, score, fps = sys.argv[1:4]
meta = json.load(open(path))
if score: meta["score"] = int(score)
if fps: meta["fps"] = int(fps)
meta["score_source"] = "manual"
json.dump(meta, open(path, "w"), indent=1, sort_keys=True)
print(f"gpu-bench: recorded against {meta['run_id']}: score={score or '-'} fps={fps or '-'}")
PYEOF
  regenerate_dashboard || true
}

do_dashboard() { regenerate_dashboard; echo "$DASHBOARD"; }

do_latest() {
  local latest=""
  local d
  for d in "$RESULTS_DIR"/*/; do [ -d "$d" ] && latest="$d"; done
  [ -n "$latest" ] || die "no runs yet under $RESULTS_DIR"
  python3 -m json.tool "${latest}meta.json"
}

main() {
  local verb="${1:-}"
  case "$verb" in
    check) shift; do_check "$@" ;;
    bench) shift; do_bench "$@" ;;
    stress) shift; do_stress "$@" ;;
    vram) shift; do_vram "$@" ;;
    record) shift; do_record "$@" ;;
    dashboard) do_dashboard ;;
    latest) do_latest ;;
    ""|-h|--help|help) usage ;;
    *) die "unknown verb: $verb (try: gpu-bench help)" ;;
  esac
}

main "$@"
