#!/usr/bin/env bash
# guardrails — what is this, and how do I use it. A terminal answer to "a teammate
# added guardrails to our repo; now what?". Print with `guardrails` or `guardrails info`.
set -uo pipefail
case "${1:-info}" in
  info | "" | -h | --help | help) ;;
  *) echo "guardrails: unknown command '$1' (try: guardrails info)" >&2 ;;
esac
cat <<'EOF'
guardrails — shareable code-quality / governance for this repo.
Gates run on every commit (via prek); deep checks (cargo-deny, perf) run in CI.

GATES — block a commit unless escaped:
  no-fake-impl        todo!()/unimplemented!()/FIXME/placeholder-impl — stubs shipped as "done"
  no-debug-leftovers  dbg!/print!/println!/eprint!/eprintln!/console.log outside main/bin/tests
  no-commented-code   commented-out code graveyards
  no-hardcoded        magic values that should be tunables (src/ only)
  + gitleaks · rustfmt · clippy -D warnings · cargo-deny
CI-deep (not pre-commit) — run after `cargo criterion`:
  perf-budget         gate criterion regressions over a checked-in perf-budgets.toml
  perf-record         append per-bench medians to perf-history.csv — the PR diff is the report,
                      git history is the trend (no external service)

ESCAPE / BYPASS:
  one line    append  // guardrails-ok
  one commit  git commit --no-verify   (sparingly — the point is to not need it)

CONFIG KNOBS (in your repo root):
  .pre-commit-config.yaml  which gates run + their entries
  GUARDRAILS_OUTPUT_GLOBS  no-debug-leftovers: colon-sep path globs for legit CLI output surfaces,
                           e.g.  entry: env GUARDRAILS_OUTPUT_GLOBS=*/cli/*:scripts/* guardrails-no-debug-leftovers
  guardrails-allow.txt     no-hardcoded: blessed path prefixes to skip
  perf-budgets.toml        perf-budget: criterion median ceilings (run after `cargo criterion`)
  perf-history.csv         perf-record: committed per-bench history; the PR diff = the perf report
  deny.toml                cargo-deny: license allow-list + advisory ignores

WIRE THE HOOKS (normally automatic via direnv / nix develop):
  just install-hooks    or    prek install -t pre-commit -t commit-msg

MORE: docs/CONVENTIONS.md · github:gerchowl/guardrails
EOF
