#!/usr/bin/env python3
"""gpu-bench dashboard generator.

Reads run artifacts produced by gpu_bench-v1.0.4.sh (results/<run>/meta.json,
telemetry.csv, score.env) and renders one self-contained HTML dashboard:
latest score per lane, full run history, and per-run temperature/power
charts as inline SVG. No external assets.

Usage: gpu_bench_dashboard.py <results_dir> <output_html>
"""
import csv
import html
import json
import os
import sys


def load_runs(results_dir):
    runs = []
    if not os.path.isdir(results_dir):
        return runs
    for name in sorted(os.listdir(results_dir)):
        rdir = os.path.join(results_dir, name)
        meta_path = os.path.join(rdir, "meta.json")
        if not os.path.isfile(meta_path):
            continue
        try:
            with open(meta_path) as f:
                meta = json.load(f)
        except (OSError, json.JSONDecodeError):
            continue
        meta["_dir"] = rdir
        meta["_telemetry"] = read_telemetry(os.path.join(rdir, "telemetry.csv"))
        runs.append(meta)
    runs.sort(key=lambda m: m.get("run_id", ""), reverse=True)
    return runs


def read_telemetry(path):
    rows = []
    try:
        with open(path) as f:
            for row in csv.DictReader(f):
                try:
                    temp = float(row["temp_c"]) if row["temp_c"] else None
                    power = float(row["power_w"]) if row["power_w"] else None
                    rows.append(
                        {
                            "t": int(row["epoch"]),
                            "temp": temp if temp and temp > 0 else None,
                            "power": power if power and power > 0 else None,
                        }
                    )
                except (KeyError, TypeError, ValueError):
                    continue
    except OSError:
        pass
    return rows


def svg_chart(rows, key, color, width=520, height=110, max_points=240):
    pts = [(r["t"], r[key]) for r in rows if r.get(key) is not None]
    if len(pts) < 2:
        return '<p class="muted">no telemetry</p>'
    if len(pts) > max_points:
        step = len(pts) / max_points
        pts = [pts[int(i * step)] for i in range(max_points)]
    t0, t1 = pts[0][0], pts[-1][0]
    vals = [v for _, v in pts]
    vmin, vmax = min(vals), max(vals)
    label = f"max {vmax:g} · min {vmin:g}"
    if vmax == vmin:
        vmax = vmin + 1
    span_t = max(t1 - t0, 1)
    coords = []
    for t, v in pts:
        x = 6 + (t - t0) / span_t * (width - 12)
        y = height - 14 - (v - vmin) / (vmax - vmin) * (height - 26)
        coords.append(f"{x:.1f},{y:.1f}")
    return (
        f'<svg width="{width}" height="{height}" class="chart" role="img">'
        f'<polyline fill="none" stroke="{color}" stroke-width="1.6" '
        f'points="{" ".join(coords)}"/>'
        f'<text x="6" y="12" class="chart-label">{label}</text></svg>'
    )


def fmt(v, suffix=""):
    if v is None or v == "":
        return "—"
    return f"{v}{suffix}"


def main():
    results_dir, out_path = sys.argv[1], sys.argv[2]
    runs = load_runs(results_dir)

    # Latest score per lane (host, backend, api, preset)
    lanes = {}
    for r in runs:
        if "score" not in r and "fps" not in r:
            continue
        key = (
            r.get("host", ""),
            r.get("backend", ""),
            r.get("api", ""),
            r.get("preset", ""),
        )
        if key not in lanes:
            lanes[key] = r

    lane_rows = (
        "".join(
            "<tr>"
            f"<td>{html.escape(str(k[0]))}</td><td>{html.escape(str(k[1]))}</td>"
            f"<td>{html.escape(str(k[2]))}</td><td>{html.escape(str(k[3]))}</td>"
            f"<td class='num'><strong>{html.escape(str(r['score'])) if 'score' in r else '—'}</strong></td>"
            f"<td class='num'>{fmt(r.get('fps'))}</td>"
            f"<td class='num'>{fmt(r.get('temp_max_c'), ' °C')}</td>"
            f"<td class='num'>{fmt(r.get('power_max_w'), ' W')}</td>"
            f"<td>{html.escape(str(r.get('run_id', ''))[:15])}</td>"
            "</tr>"
            for k, r in sorted(lanes.items())
        )
        or '<tr><td colspan="9" class="muted">No scored runs yet.</td></tr>'
    )

    run_blocks = []
    for r in runs[:12]:
        tele = r["_telemetry"]
        score_bits = f" · score {fmt(r.get('score'))} · fps {fmt(r.get('fps'))}"
        if r.get("score_source"):
            score_bits += f" ({html.escape(r['score_source'])})"
        run_blocks.append(
            '<section class="run">'
            f"<h3>{html.escape(r.get('run_id', ''))}</h3>"
            f"<p class='meta'>{html.escape(r.get('backend', ''))} · {html.escape(r.get('mode', ''))}"
            f" · api {html.escape(r.get('api', ''))} · preset {html.escape(r.get('preset', ''))}"
            f" · host {html.escape(r.get('host', ''))} · {fmt(r.get('elapsed_s'), ' s')}"
            f" · exit {fmt(r.get('exit_code'))}"
            f"{score_bits}"
            f" · max temp {fmt(r.get('temp_max_c'), ' °C')}"
            f" · max power {fmt(r.get('power_max_w'), ' W')}</p>"
            f"<p class='meta muted'>{html.escape(r.get('os', ''))} · kernel {html.escape(r.get('kernel', ''))}</p>"
            '<div class="charts">'
            f"<div><h4>Temperature °C</h4>{svg_chart(tele, 'temp', '#e8833a')}</div>"
            f"<div><h4>Power W</h4>{svg_chart(tele, 'power', '#3a9be8')}</div>"
            "</div></section>"
        )

    doc = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>gpu-bench dashboard</title>
<style>
  body {{ background:#101418; color:#dfe6ec; font-family:system-ui, sans-serif; margin:2rem; }}
  h1 {{ font-size:1.4rem; }} h3 {{ margin-bottom:.2rem; }} h4 {{ margin:.4rem 0; font-weight:600; }}
  table {{ border-collapse:collapse; width:100%; margin:1rem 0 2rem; }}
  th, td {{ border-bottom:1px solid #26313a; padding:.4rem .6rem; text-align:left; }}
  td.num, th.num {{ text-align:right; }}
  .run {{ border:1px solid #26313a; border-radius:8px; padding:1rem 1.2rem; margin:1rem 0; }}
  .meta {{ color:#9fb0bd; margin:.2rem 0; }} .muted {{ color:#67788a; }}
  .charts {{ display:flex; gap:2rem; flex-wrap:wrap; }}
  .chart {{ background:#161c22; border-radius:6px; }}
  .chart-label {{ fill:#9fb0bd; font-size:10px; }}
  .note {{ color:#9fb0bd; max-width:60rem; }}
</style>
</head>
<body>
<h1>gpu-bench dashboard</h1>
<p class="note">Scores compare only within a lane: same backend, API, preset, and driver stack.
FurMark is a worst-case power/thermal load, not a gaming benchmark; OCCT rows are stability
sessions (an unparsed score is normal), and glmark2/vkmark rows are quick driver sanity scores.
Generated from {len(runs)} run(s) under {html.escape(results_dir)}.</p>
<h2>Latest score per lane</h2>
<table>
<tr><th>Host</th><th>Backend</th><th>API</th><th>Preset</th><th class="num">Score</th><th class="num">FPS</th><th class="num">Max temp</th><th class="num">Max power</th><th>Run</th></tr>
{lane_rows}
</table>
<h2>Recent runs</h2>
{''.join(run_blocks) or '<p class="muted">No runs yet. First: gpu-bench check, then gpu-bench bench furmark.</p>'}
</body>
</html>
"""
    with open(out_path, "w") as f:
        f.write(doc)
    print(f"dashboard written: {out_path} ({len(runs)} runs)")


if __name__ == "__main__":
    main()
