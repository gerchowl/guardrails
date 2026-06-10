#!/usr/bin/env bash
# guardrails: perf-budget — gate criterion regressions against a checked-in budgets file.
#
# Run AFTER your benches (`cargo criterion` or `cargo bench`) have written results to
# target/criterion. This gate only COMPARES — fast and deterministic, no measurement here.
#
# Usage: guardrails-perf-budget [perf-budgets.toml] [target/criterion]
#   gate-mode budgets fail the build on regression; nudge-mode only warn. The threshold is a
#   per-budget `tolerance` (fractional headroom over budget; default 0.20 = 20%), matching the
#   "gate big regressions, nudge the rest" methodology in docs/CONVENTIONS.md.
#
# perf-budgets.toml:
#   default_tolerance = 0.20
#   [bench."parser/parse_frame"]   # key = criterion benchmark id (its target/criterion/<id> path)
#   budget_ns = 1500
#   mode = "gate"                  # gate | nudge
#   # tolerance = 0.10             # optional per-budget override
set -uo pipefail
budgets="${1:-perf-budgets.toml}"
crit_dir="${2:-target/criterion}"

if [ ! -f "$budgets" ]; then
  echo "guardrails/perf-budget: no $budgets — skipping (add one to enable perf gating)." >&2
  exit 0
fi

exec python3 - "$budgets" "$crit_dir" <<'PY'
import json, pathlib, sys
try:
    import tomllib
except ModuleNotFoundError:
    sys.stderr.write("guardrails/perf-budget: needs python>=3.11 (tomllib) on PATH.\n")
    sys.exit(0)

budgets_path, crit = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
spec = tomllib.loads(budgets_path.read_text())
default_tol = float(spec.get("default_tolerance", 0.20))
benches = spec.get("bench", {})

ok, warnings, failures = [], [], []
for bid, cfg in benches.items():
    budget = float(cfg["budget_ns"])
    mode = cfg.get("mode", "gate")
    tol = float(cfg.get("tolerance", default_tol))
    est = crit / bid / "new" / "estimates.json"
    if not est.exists():
        warnings.append(f"{bid}: no criterion data at {est} — run the benches first")
        continue
    median = float(json.loads(est.read_text())["median"]["point_estimate"])
    limit = budget * (1 + tol)
    pct = (median / budget - 1) * 100
    line = f"{bid}: median {median:.0f}ns vs budget {budget:.0f}ns ({pct:+.1f}%, +{tol*100:.0f}% allowed)"
    if median > limit:
        (failures if mode == "gate" else warnings).append(line)
    else:
        ok.append(line)

for m in ok:
    print(f"  ok    {m}")
for m in warnings:
    sys.stderr.write(f"  warn  {m}\n")
for m in failures:
    sys.stderr.write(f"  FAIL  {m}\n")

if failures:
    sys.stderr.write(
        f"guardrails/perf-budget: {len(failures)} gated regression(s) over budget — "
        "optimize, or raise the budget if the cost is justified and recorded.\n"
    )
    sys.exit(1)
PY
