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
The devShell brings the toolbelt and auto-runs `prek install` when a `.pre-commit-config.yaml` is present.

## What's wired (this MVP)

- **Gates** (`gates/*.sh`, on PATH as `guardrails-<name>`, run by `prek`):
  - `no-fake-impl` — `todo!`/`unimplemented!`/stub/placeholder/FIXME (deceptive "done"). **GATE**
  - `no-debug-leftovers` — `dbg!`/`println!`/`console.log` outside main/bin/tests. **GATE**
  - `no-commented-code` — commented-out code graveyards. **GATE**
  - + off-the-shelf in `.pre-commit-config.yaml`: gitleaks, rustfmt, clippy `-D warnings`, cargo-deny.
  - Escape hatch on any line: `guardrails-ok`.
- **Toolbelt** (`lib.mkDevShell`): prek, gitleaks, cargo-deny, cargo-machete, cargo-mutants,
  cargo-bloat, tokei.
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

1. ~~Tunables registry~~ ✅ **shipped** (`crates/tunables/`). Next: a no-hardcoded-values gate that
   checks every numeric literal is either primitive-allow or inside a `const_tunable!`/`config!`,
   and a `tunables` CLI/build-step that regenerates `TUNABLES.md` in CI.
2. **`tracing` starter layer** — a small crate/snippet: `EnvFilter` subscriber + structured local
   JSONL layer + the level contract, with `release_max_level_*` + `profiling`/`dhat` features
   pre-wired (Tier-1/2/3 from CONVENTIONS). One drop-in for the whole observability spine.
3. **Perf harness wiring** — criterion + CodSpeed CI action + a `perf-budgets` file + gate, with the
   honest-measurement methodology baked in.
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
