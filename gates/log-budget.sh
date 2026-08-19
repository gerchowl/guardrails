#!/usr/bin/env bash
# guardrails: log-budget — gate a REPRESENTATIVE log against a checked-in budgets file.
#
# The first gate here that reads a LOG instead of SOURCE. That distinction is the whole point:
# every other gate greps for a forbidden token in a file that exists, so it can only ever catch
# what IS there. Two of the most expensive logging defects are invisible to that shape:
#
#   * NOISE — one event drowning the stream. Level-vs-frequency ("info is never per-iteration",
#     docs/CONVENTIONS.md) cannot be checked lexically once a repo routes events through a logging
#     FACADE: the `info!` sits in a one-line helper, the loop is in another file, and a source scan
#     scores the repo 100% clean while it writes 15MB/day. Measured, it is a one-line verdict.
#   * SILENCE — an operation that emits NOTHING. Absence is only checkable against an ENUMERABLE
#     population (the `adr-matrix` lesson: it works because Accepted-ADR rows enumerate what must be
#     projected). A source tree does not enumerate "operations that must be observable"; this
#     budgets file DOES. Declaring an event under [require] is what makes its absence detectable.
#
# So one mechanism, two directions: `max_pct` bounds an event from above, `require` bounds a
# declared event from below. Deterministic — it compares an observed distribution to declared
# numbers, no heuristics, so it GATES rather than nudges (docs/CONVENTIONS.md: hard-gate
# deterministic high-confidence, nudge probabilistic).
#
# Like perf-budget, this gate only COMPARES. Producing the sample is the repo's job (run a real
# workload, or have CI drive one) — measured, not inferred. NO budgets file → skip, exit 0: a new
# gate in a shared flake must not fire on every consumer's untouched code the day they update.
#
# Usage: guardrails-log-budget [log-budgets.toml] [sample.jsonl]
#   sample defaults to the `sample` key in the budgets file, else $GUARDRAILS_LOG_SAMPLE.
#   GUARDRAILS_LOG_ENFORCE=1 promotes every nudge-mode finding to a hard failure.
#
# log-budgets.toml:
#   sample = "logs/session.jsonl"   # representative JSONL log (one JSON object per line)
#   event_field = "event"           # key naming the event id; falls back to target+message
#   default_max_pct = 5.0           # no single event id may exceed this % of the stream
#
#   [event."client.tick"]
#   max_pct = 0.5                   # per-event override
#   mode = "gate"                   # gate | nudge  (default gate)
#
#   [require."client.slot.flipped"] # ABSENCE: this event MUST appear in the sample
#   min_count = 1
#   mode = "gate"
set -uo pipefail

case "${1:-}" in -h | --help) sed -n '2,/^set /p' "$0" | sed 's/^# \{0,1\}//; /^set /d'; exit 0 ;; esac

budgets="${1:-log-budgets.toml}"
sample="${2:-}"

if [ ! -f "$budgets" ]; then
  echo "guardrails/log-budget: no $budgets — skipping (add one to enable log gating)." >&2
  exit 0
fi

exec python3 - "$budgets" "$sample" "${GUARDRAILS_LOG_SAMPLE:-}" "${GUARDRAILS_LOG_ENFORCE:-}" <<'PY'
import json, pathlib, sys

try:
    import tomllib
except ModuleNotFoundError:
    sys.stderr.write("guardrails/log-budget: needs python>=3.11 (tomllib) on PATH.\n")
    sys.exit(0)

budgets_path = pathlib.Path(sys.argv[1])
cli_sample, env_sample, enforce = sys.argv[2], sys.argv[3], sys.argv[4] == "1"

try:
    cfg = tomllib.loads(budgets_path.read_text())
except (OSError, tomllib.TOMLDecodeError) as err:
    sys.stderr.write(f"guardrails/log-budget: cannot read {budgets_path}: {err}\n")
    sys.exit(1)

# Precedence: explicit arg > budgets file > env. The file is the checked-in default so CI and a
# developer's local run agree without anyone remembering to export anything.
sample_path = cli_sample or cfg.get("sample") or env_sample
if not sample_path:
    sys.stderr.write("guardrails/log-budget: no sample log (set `sample` in the budgets file, "
                     "pass one as argv[2], or export GUARDRAILS_LOG_SAMPLE) — skipping.\n")
    sys.exit(0)

sample_file = pathlib.Path(sample_path)
if not sample_file.is_file():
    sys.stderr.write(f"guardrails/log-budget: sample log {sample_file} not found — skipping.\n")
    sys.exit(0)

def die(message):
    """A config mistake is the USER's error to fix, not a stack trace to decode."""
    sys.stderr.write(f"guardrails/log-budget: {budgets_path.name}: {message}\n")
    sys.exit(2)


def as_number(value, cast, where):
    try:
        return cast(value)
    except (TypeError, ValueError):
        die(f"{where} must be a number, got {value!r}")


def as_table(value, where):
    if not isinstance(value, dict):
        die(f"[{where}] must be a table (e.g. `[{where}]` with `min_count = 1`), got {value!r}")
    return value


VALID_MODES = ("gate", "nudge")


def as_mode(entry, where):
    """An unrecognised mode used to fall through to nudge — so `mode = "Gate"` silently disabled
    enforcement on the very entry the author wrote to enforce. Reject it loudly instead."""
    mode = entry.get("mode", "gate")
    if mode not in VALID_MODES:
        die(f"{where}: mode must be one of {VALID_MODES}, got {mode!r}")
    return mode


event_field = cfg.get("event_field", "event")
default_max_pct = as_number(cfg.get("default_max_pct", 5.0), float, "default_max_pct")
event_cfg = as_table(cfg.get("event", {}), "event")
require_cfg = as_table(cfg.get("require", {}), "require")

# Validate every declared entry EAGERLY. Checking an entry only when its event happens to appear in
# the sample meant a malformed entry for an absent event was never seen at all.
for _section, _table in (("event", event_cfg), ("require", require_cfg)):
    for _name, _entry in sorted(_table.items()):
        _where = f'{_section}."{_name}"'
        as_mode(as_table(_entry, _where), _where)


def event_id(record):
    """Identify an event. The explicit id field wins; otherwise fall back to target+message so a
    repo that has not adopted a canonical event id still gets a usable bucketing."""
    value = record.get(event_field)
    if isinstance(value, str) and value:
        return value
    target, message = record.get("target", ""), record.get("message", "")
    return f"{target}:{message}".strip(":") or "<unidentified>"


counts, total, malformed = {}, 0, 0
with sample_file.open(encoding="utf-8", errors="replace") as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            # A truncated tail is normal on a live log — count it, never crash on it.
            malformed += 1
            continue
        if not isinstance(record, dict):
            malformed += 1
            continue
        total += 1
        counts[event_id(record)] = counts.get(event_id(record), 0) + 1

if total == 0:
    sys.stderr.write(f"guardrails/log-budget: {sample_file} has no parseable records — skipping.\n")
    sys.exit(0)

gate_hits, nudge_hits = [], []


def record_finding(mode, message):
    (gate_hits if (mode == "gate" or enforce) else nudge_hits).append(message)


# --- direction 1: NOISE — no event may exceed its ceiling -----------------------------------
# Sorted by descending share then id so the report is byte-identical across runs (guardrails bans
# wall-clock/random for reproducibility; dict order would otherwise leak insertion order).
for name, count in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])):
    entry = as_table(event_cfg.get(name, {}), f'event."{name}"')
    ceiling = as_number(entry.get("max_pct", default_max_pct), float, f'event."{name}".max_pct')
    share = 100.0 * count / total
    if share > ceiling:
        record_finding(
            as_mode(entry, f'event."{name}"'),
            f"{name}: {share:.1f}% of {total} records ({count}) exceeds max_pct {ceiling:g}",
        )

# M2: a ceiling declared for an event that never appears is usually a TYPO in the event id, and
# silently does nothing — exactly the failure the author was trying to prevent.
for name in sorted(event_cfg):
    if name not in counts:
        sys.stderr.write(
            f"guardrails/log-budget: {budgets_path.name}: [event.\"{name}\"] declares a ceiling "
            f"for an event absent from {sample_file.name} — typo, or stale entry?\n"
        )

# --- direction 2: SILENCE — declared events must actually appear ----------------------------
for name in sorted(require_cfg):
    # M1: `[require]` + `x = 5` is a natural mistake for `[require."x"] min_count = 5`. Silently
    # coercing it to min_count=1 discarded the author's number.
    entry = as_table(require_cfg[name], f'require."{name}"')
    minimum = as_number(entry.get("min_count", 1), int, f'require."{name}".min_count')
    seen = counts.get(name, 0)
    if seen < minimum:
        record_finding(
            as_mode(entry, f'require."{name}"'),
            f"{name}: required event seen {seen}x, expected >= {minimum} "
            f"(declared in {budgets_path.name} but the operation logged nothing)",
        )

if malformed:
    sys.stderr.write(f"guardrails/log-budget: skipped {malformed} unparseable line(s) in {sample_file}.\n")

for message in gate_hits + nudge_hits:
    print(f"{sample_file}: {message}")

if gate_hits:
    tail = f" (+{len(nudge_hits)} nudge-mode)" if nudge_hits else ""
    sys.stderr.write(
        f"guardrails/log-budget: {len(gate_hits)} budget violation(s){tail} in {sample_file}. "
        "Fix the level/instrumentation, or adjust log-budgets.toml deliberately.\n"
    )
    sys.exit(1)

if nudge_hits:
    sys.stderr.write(
        f"nudge: {len(nudge_hits)} log-budget finding(s) in {sample_file} "
        "(mode=nudge; GUARDRAILS_LOG_ENFORCE=1 to enforce).\n"
    )

sys.exit(0)
PY
