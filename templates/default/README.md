# my-repo

Wired to [**guardrails**](https://github.com/gerchowl/guardrails) — shared code-quality gates so the
discipline is the same everywhere instead of reinvented per repo.

## Setup (once)

```sh
direnv allow      # or: nix develop
```

This brings the toolbelt onto PATH and installs the git hooks. From then on, **commits are gated**:
`no-fake-impl`, `no-debug-leftovers`, `no-commented-code`, `no-hardcoded`, plus gitleaks, rustfmt,
`clippy -D warnings`, and cargo-deny.

## Day to day

- **What are the gates and config knobs?** Run `guardrails info`.
- **Escape one line:** append `// guardrails-ok`.
- **Bypass one commit:** `git commit --no-verify` (sparingly — the point is to not need it).
- **Tune:** `.pre-commit-config.yaml` (which gates), `deny.toml` (licenses/advisories),
  `perf-budgets.toml` (perf ceilings), `numerical-obligation.toml` (ratcheting quality
  contracts — parity errors, HARD counts, coverage %, binary size). See `guardrails info`
  for every knob.

Conventions (the gate/nudge/CI matrix, tracing spine, perf methodology): see
[`docs/CONVENTIONS.md`](https://github.com/gerchowl/guardrails/blob/main/docs/CONVENTIONS.md).
