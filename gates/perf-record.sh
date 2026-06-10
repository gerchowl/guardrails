#!/usr/bin/env bash
# guardrails: perf-record — append a perf report row per benchmark to a committed CSV.
#
# Run after `cargo criterion`. Parses criterion's medians and writes one row per benchmark to
# perf-history.csv (created if missing). Commit that CSV: the PR diff IS the perf report, and git
# history IS the trend — no external service. Pairs with the perf-budget gate (absolute ceilings);
# this is the visible per-PR delta + history. Re-running on the same commit refreshes its rows.
#
# Usage: guardrails-perf-record [perf-history.csv] [perf-budgets.toml] [target/criterion]
# Columns: date,commit,bench,median_ns,budget_ns,vs_budget_pct,vs_prev_pct
set -uo pipefail
csv="${1:-perf-history.csv}"
budgets="${2:-perf-budgets.toml}"
crit_dir="${3:-target/criterion}"

# GUARDRAILS_PERF_COMMIT overrides the recorded commit (CI / tests); else the short HEAD sha.
commit="${GUARDRAILS_PERF_COMMIT:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}"
if [ -z "${GUARDRAILS_PERF_COMMIT:-}" ] && ! git diff --quiet 2>/dev/null; then
  commit="$commit-dirty"
fi
now="${GUARDRAILS_PERF_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

exec python3 - "$csv" "$budgets" "$crit_dir" "$commit" "$now" <<'PY'
import csv, json, pathlib, sys
csv_path, budgets_path, crit_dir, commit, now = sys.argv[1:6]
crit = pathlib.Path(crit_dir)
header = ["date", "commit", "bench", "median_ns", "budget_ns", "vs_budget_pct", "vs_prev_pct"]

budgets = {}
bp = pathlib.Path(budgets_path)
if bp.exists():
    try:
        import tomllib
        for bid, cfg in tomllib.loads(bp.read_text()).get("bench", {}).items():
            budgets[bid] = float(cfg["budget_ns"])
    except Exception:
        pass

cp = pathlib.Path(csv_path)
existing = list(csv.DictReader(cp.open())) if cp.exists() else []

# previous median per bench = last recorded row from a DIFFERENT commit (ignore -dirty suffix)
base = commit.split("-dirty")[0]
prev = {}
for r in existing:
    if r["commit"].split("-dirty")[0] != base:
        try:
            prev[r["bench"]] = float(r["median_ns"])
        except ValueError:
            pass

new_rows = []
for est in sorted(crit.glob("**/new/estimates.json")):
    bid = str(est.parent.parent.relative_to(crit))
    try:
        median = float(json.loads(est.read_text())["median"]["point_estimate"])
    except Exception:
        continue
    budget = budgets.get(bid)
    vsb = f"{(median / budget - 1) * 100:+.1f}" if budget else ""
    vsp = f"{(median / prev[bid] - 1) * 100:+.1f}" if bid in prev else ""
    new_rows.append({
        "date": now, "commit": commit, "bench": bid, "median_ns": f"{median:.0f}",
        "budget_ns": f"{budget:.0f}" if budget else "", "vs_budget_pct": vsb, "vs_prev_pct": vsp,
    })

if not new_rows:
    sys.stderr.write(f"guardrails/perf-record: no criterion results under {crit_dir} — run `cargo criterion` first.\n")
    sys.exit(0)

kept = [r for r in existing if r["commit"] != commit]  # refresh this commit's rows
with cp.open("w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=header)
    w.writeheader()
    w.writerows(kept + new_rows)

print(f"guardrails/perf-record: {len(new_rows)} benchmark(s) -> {csv_path} @ {commit}")
for r in new_rows:
    extra = [x for x in (
        f"vs prev {r['vs_prev_pct']}%" if r["vs_prev_pct"] else "",
        f"vs budget {r['vs_budget_pct']}%" if r["vs_budget_pct"] else "",
    ) if x]
    print(f"  {r['bench']}: {r['median_ns']}ns" + (f" ({', '.join(extra)})" if extra else ""))
PY
