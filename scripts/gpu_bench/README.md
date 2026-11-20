# gpu-bench v1.0.4 — GPU benchmark and stress harness for Linux

One harness around six backends, with the same envelope for every run:
GPU inventory, live telemetry sampled from the amdgpu driver every 2
seconds, a dated run directory of artifacts, score extraction where the
backend emits one, and an HTML dashboard regenerated from all artifacts.

## Backends

| Backend | Role | How it is installed |
| --- | --- | --- |
| FurMark 2 | Primary: worst-case power/thermal stress + quick 60 s scores | Flatpak: `flatpak install flathub com.geeks3d.furmark` (2.11.0.4; use at least 2.10.2 — older builds carry an RX 6000/7000 Vulkan bug and a Wayland GUI crash) |
| OCCT (Linux) | Error-detected stability validation (3D + VRAM) | Download from ocbase.com, set `OCCT_BIN` |
| Superposition | Game-like OpenGL benchmark score | Download the .run from benchmark.unigine.com, set `SUPERPOSITION_BIN` |
| GravityMark | Modern cross-API benchmark score | Download from gravitymark.tellusim.com, set `GRAVITYMARK_BIN` |
| glmark2 | Quick OpenGL driver sanity score (not a stress test) | `sudo dnf install glmark2` |
| vkmark | Quick Vulkan driver sanity score (not a stress test) | `sudo dnf install vkmark` |

## Install

Copy `gpu_bench-v1.0.4.sh` and `gpu_bench_dashboard.py` into the same
directory on the target machine, `chmod +x` both, and run:

```bash
./gpu_bench-v1.0.4.sh check
./gpu_bench-v1.0.4.sh check --probe
```

`check` prints the GPU inventory, telemetry availability, and which
backends resolve. `--probe` additionally captures each template backend's
`--help` into `~/gpu-bench/probe/` — wire that backend's arguments from
its own help output via the `GPU_BENCH_<BACKEND>_ARGS` environment
variable rather than trusting third-party flag lists.

## Usage

```bash
gpu-bench bench furmark --api gl --preset 1080
gpu-bench bench furmark --api vk --preset 1440
gpu-bench stress furmark --minutes 15
gpu-bench vram --gb 10 --minutes 5
gpu-bench bench glmark2
gpu-bench bench vkmark
gpu-bench bench occt --minutes 20
gpu-bench dashboard
gpu-bench latest
```

- FurMark presets (1080 / 1440 / uw1440 / 2160) are timed 60-second
  benchmarks reporting points and FPS. Stress runs the demo until the
  minute bound. The VRAM verb uses FurMark's VRAM test demo.
- The FurMark command line uses only the flags corroborated by
  Geeks3D's own release notes (`-demo furmark-gl|furmark-vk`,
  `--p<WIDTHxHEIGHT>`, `-furmark-vram-test-gb N`). The elaborate flag
  sets in blog posts (`--api`, `--resolution`, `--output file.json`)
  are not corroborated by Geeks3D; this tool does not use them. Stress
  duration is bounded by `timeout`, not by an unverified flag.
- OCCT, Superposition, and GravityMark launch through a command
  template: the resolved binary plus `GPU_BENCH_<BACKEND>_ARGS`. The
  envelope records telemetry and the session log for the configured
  minutes or until the program exits, so GUI-driven sessions still
  produce full run artifacts. Scores are parsed when the backend's
  output contains one and recorded as unparsed otherwise.

## Artifacts and dashboard

Runs land in `~/gpu-bench/results/<run-id>/` (override with
`GPU_BENCH_HOME`):

- `meta.json` — host, backend, mode, API, preset, exit code, elapsed,
  OS and kernel, parsed score/FPS, telemetry maxima
- `telemetry.csv` — per-sample epoch, temperature, power, fan RPM,
  GPU busy %, VRAM used, core clock
- `backend.log` — the backend's full captured output
- `score.env` — parsed score fields and their provenance

`~/gpu-bench/dashboard.html` is regenerated after every run: latest
score per lane, run history, and per-run temperature/power charts.

**Score lanes:** a score compares only against runs with the same
backend, API, preset, and driver stack. A Linux/Mesa score and a
Windows-driver score mostly compare drivers. FurMark's load is a
deliberate power virus: it validates cooling, power delivery, and
worst-case thermals, and does not prove game stability — that is what
the OCCT backend is for.

## Testing hooks

`GPU_BENCH_SYSFS` overrides the sysfs root and `FURMARK_BIN` /
`OCCT_BIN` / `SUPERPOSITION_BIN` / `GRAVITYMARK_BIN` override backend
resolution, so the full pipeline can be exercised against fixture GPUs
and stub backends.
