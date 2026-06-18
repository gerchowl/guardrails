#!/usr/bin/env bash
# guardrails — what is this, and how do I use it. A terminal answer to "a teammate
# added guardrails to our repo; now what?". Print with `guardrails` or `guardrails info`.
set -uo pipefail
case "${1:-info}" in
  info | "" | -h | --help | help) ;;
  freshness) shift; exec guardrails-freshness "$@" ;;
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
  no-conflict-markers committed <<<<<<</=======/>>>>>>> merge-marker lines (no escape — never legitimate)
  no-raw-trace-fields raw ?/% Debug/Display field formatters in tracing! macros — shape the field
                      in your schema surface (PII/secrets leak into logs by reflex otherwise)
  derived-docs        regions marked `<!-- guardrails:derived cmd="…" -->` must match `cmd`'s output
                      (re-run with --fix to regenerate; commands run with repo-hook trust)
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
  GUARDRAILS_TRACE_ALLOW_GLOBS  no-raw-trace-fields: colon-sep path globs for the schema/redaction
                           surface where raw ?/% field formatting is defined, e.g. src/trace_schema.rs
  guardrails-allow.txt     no-hardcoded: blessed path prefixes to skip
  GUARDRAILS_ENV_PREFIXES  no-hardcoded: colon-sep env-var name prefixes to flag as bare string
                           literals (write the shared const instead), e.g. "MYAPP_:OTHER_"
  perf-budgets.toml        perf-budget: criterion median ceilings (run after `cargo criterion`)
  perf-history.csv         perf-record: committed per-bench history; the PR diff = the perf report
  deny.toml                cargo-deny: license allow-list + advisory ignores

WIRE THE HOOKS (normally automatic via direnv / nix develop — both stages):
  just install-hooks    or    prek install -t pre-commit -t pre-push

FLAKE FRESHNESS (off the hot path — on demand, not on `cd`):
  guardrails freshness            this flake's inputs by lock age (offline)
  guardrails freshness --online   also flag inputs whose upstream ref moved
  guardrails freshness --json     machine output (fleet dashboard / push-time nudge)

MORE: docs/CONVENTIONS.md · github:gerchowl/guardrails
EOF
