# guardrails

Shareable code-quality / observability / perf **governance** for repos — gates + toolbelt +
conventions, packaged as a Nix flake so the discipline is wired the same way everywhere instead of
reinvented (and drifting) per repo. Built to counter *agent drift*: hard-gate the high-confidence
stuff, nudge the rest, run deep checks async — all auditable from one surface.

## Consume it (cross-repo)

```nix
# your repo's flake.nix
inputs.guardrails.url = "github:gerchowl/guardrails";
# …
devShells.default = guardrails.lib.${system}.mkDevShell { inherit pkgs; extra = [ /* your tools */ ]; };
```
…or scaffold a fresh repo: `nix flake init -t github:gerchowl/guardrails`.
The devShell brings the toolbelt and auto-runs `prek install` when a `.pre-commit-config.yaml` is present. The installed hook **self-bootstraps the devShell** (direnv, else `nix develop`), so commits from merges, worktrees, or a plain shell still run the gates instead of erroring on a missing toolbelt.

## What's wired (this MVP)

- **Gates** (`gates/*.sh`, on PATH as `guardrails-<name>`, run by `prek`):
  - `no-fake-impl` — `todo!`/`unimplemented!`/`FIXME`/`placeholder impl` (deceptive "done"). **GATE**
  - `no-debug-leftovers` — `dbg!`/`print!`/`println!`/`eprint!`/`eprintln!`/`console.log` outside main/bin/tests. **GATE** (CLI output surfaces: set `GUARDRAILS_OUTPUT_GLOBS="*/cli/*:..."` to allow them.)
  - `no-commented-code` — commented-out code graveyards. **GATE**
  - `no-hardcoded` — magic values that should be tunables (`src/` only; bless prefixes in `guardrails-allow.txt`). **GATE**
  - `perf-budget` — gate criterion regressions against a checked-in `perf-budgets.toml`. **GATE/NUDGE**
    (CI-deep, not pre-commit: run after `cargo criterion`; gate big regressions, nudge the rest.)
  - `perf-record` — append per-bench medians to a committed `perf-history.csv`. The **PR diff is the
    perf report**; git history is the trend — no external service. Flow:
    `cargo criterion && guardrails-perf-record && guardrails-perf-budget`, then commit the CSV.
  - + off-the-shelf in `.pre-commit-config.yaml`: gitleaks, rustfmt, clippy `-D warnings`, cargo-deny.
  - Escape hatch on any line: `guardrails-ok`. **`guardrails info`** prints the gates + every config knob.
- **Toolbelt** (`lib.mkDevShell`): `guardrails` (info), prek, gitleaks, cargo-deny, cargo-machete,
  cargo-mutants, cargo-bloat, cargo-criterion, tokei, python3.
- **`checks`**: `nix flake check` runs the gates over this repo.
- **`templates.default`**: a consumer flake + config.
- **Conventions** (`docs/CONVENTIONS.md`): the gate/nudge/CI matrix, the tracing spine (logging
  levels + audit + perf + the agentic-pane trace), the **compile-target 3-tier split** for a lean
  end-product, and perf baselines/budgets/methodology.
- **Tunables registry** (`crates/tunables/`): `const_tunable!` / `config!` macros that declare a
  value at its definition site and auto-register it into one generated, scannable `TUNABLES.md`
  (co-located + auditable + can't drift — the decorator→registry that retires hand-maintained
  allowlists). Two tiers: `const` (behaviour-defining, not runtime-overridable) vs `config`
  (operator/deploy-tunable). `cargo run --example gpu_bench` generates the audit file.

## The list — what's next (roadmap, ranked)

1. ~~Tunables registry~~ ✅ **shipped** (`crates/tunables/`) + ~~no-hardcoded gate & CI regen~~ ✅
   (`gates/no-hardcoded.sh`, tracked `TUNABLES.md`, `.github/workflows/ci.yml`).
2. ~~**`tracing` starter layer**~~ ✅ **shipped** (`crates/trace/`): `init()` / `init_jsonl()` —
   `EnvFilter` + structured local
   JSONL layer + the level contract, with `release_max_level_*` + `profiling`/`dhat` features
   pre-wired (Tier-1/2/3 from CONVENTIONS). One drop-in for the whole observability spine.
3. ~~**Perf harness wiring**~~ ✅ **shipped** — `perf-budget` gates criterion medians against a
   checked-in `perf-budgets.toml`; `perf-record` appends per-bench medians to a committed
   `perf-history.csv` so the **PR diff is the perf report** and git history is the trend (no external
   service — git is the time-series store). `cargo-criterion` in the toolbelt; gate big regressions /
   nudge the rest, per the honest-measurement methodology in `docs/CONVENTIONS.md`.
4. **mutation-testing CI** — `cargo-mutants` job (test-quality signal vs coverage theater).
5. **duplication nudge** — token-based clone detector (reinvention-vs-reuse), tuned threshold.
6. **diff blast-radius nudge** — flag PRs sprawling across unrelated areas.
7. **generated escape registries** — blessed `unwrap`/dep/`todo!` lists, generated not hand-kept.
8. **non-Rust gate coverage** — the gates already handle TS/JS/Py/Go; add ecosystem tools
   (eslint/ruff) behind language detection.

## Philosophy
A check earns its place only if it catches a real defect class with a false-positive rate low enough
that nobody reflexively `--no-verify`s it. Gate the deterministic; nudge the probabilistic; run the
slow/deep async. Make exceptions explicit and auditable from one generated surface — never grep the
whole codebase to assess a policy. See `docs/CONVENTIONS.md`.
