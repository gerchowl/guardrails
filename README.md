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

`mkDevShell` takes four args — `extra` and `hook` are the common ones; `env`/`name` exist so you can
**migrate an existing `mkShell` without reaching for `.overrideAttrs`**:

```nix
devShells.default = guardrails.lib.${system}.mkDevShell {
  inherit pkgs;
  name  = "myproject-dev";                 # else the shell is named "nix-shell"
  extra = with pkgs; [ rustToolchain nodejs_22 playwright-driver.browsers ];
  env = {                                  # surfaced as environment variables in the shell
    PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
  };
  hook = ''                                # appended after the guardrails banner
    echo "myproject dev shell — rust $(rustc --version)"
  '';
};
```

To actually **gate commits** you also copy in `.pre-commit-config.yaml` (which gates run) and
`deny.toml` (cargo-deny) — `nix flake init -t github:gerchowl/guardrails` drops both, or grab them
from `templates/default/`. The input + devShell alone bring the toolbelt onto PATH; the config files
are what the hook installs.

The devShell brings the toolbelt and auto-installs **both hook stages** when a `.pre-commit-config.yaml` is present — `pre-commit` (fast content gates) and `pre-push` (slower gates the local machine runs as CI, e.g. the test suite). The pre-push shim is wired even if the config has no pre-push hooks yet, so the day you add one it's already active. The installed hooks **self-bootstrap the devShell** (direnv, else `nix develop`), so commits/pushes from merges, worktrees, or a plain shell still run the gates instead of erroring on a missing toolbelt.

## What's wired (this MVP)

- **Gates** (`gates/*.sh`, on PATH as `guardrails-<name>`, run by `prek`):
  - `no-fake-impl` — `todo!`/`unimplemented!`/`FIXME`/`placeholder impl` (deceptive "done"). **GATE**
  - `no-debug-leftovers` — `dbg!`/`print!`/`println!`/`eprint!`/`eprintln!`/`console.log` outside main/bin/tests. **GATE** (CLI output surfaces: set `GUARDRAILS_OUTPUT_GLOBS="*/cli/*:..."` to allow them.)
  - `no-raw-trace-fields` — raw `?`/`%` Debug/Display **field** formatters inside `tracing` macros
    (`info!(user = ?user)`, `debug!(%peer)`) — they splat an arbitrary value into the audit trail,
    the reflexive way PII/secrets leak. Confine raw formatting to the schema/redaction surface where
    fields are *defined*: `GUARDRAILS_TRACE_ALLOW_GLOBS="src/trace_schema.rs:..."`. String/char
    literals are blanked first, so regex patterns like `r"(?i)…"` are never mistaken for it. **GATE**
  - `no-commented-code` — commented-out code graveyards. **GATE**
  - `no-hardcoded` — magic values that should be tunables (`src/` only; bless prefixes in
    `guardrails-allow.txt`; token-level floats, underscored ints, `/Users//home//tmp` paths checked
    inside strings, opt-in env-name literals via `GUARDRAILS_ENV_PREFIXES`; block escapes
    `guardrails-ok-begin`/`-end`). **GATE**
  - `no-conflict-markers` — committed `<<<<<<<`/`=======`/`>>>>>>>` lines (a conflicted merge CAN
    be committed — git records it and `git status` is clean after; a real flake.nix went unevaluable
    this way). Deterministic, no escape. **GATE**
  - `derived-docs` — derived/generated doc regions match their source-of-truth command. Mark a
    region in any text file with (HTML-encoded here so this README isn't itself a region):
    `&lt;!-- guardrails:derived cmd="…" --&gt;` … `&lt;!-- guardrails:derived:end --&gt;`. The gate
    re-runs `cmd` (cwd = repo root, via `sh -c`), normalizes whitespace, and diffs against the
    region. Mismatch → blocks with a unified diff. Re-run with `--fix` to regenerate in place.
    Security: marker commands run with the same trust as any pre-commit hook in the repo — review
    them like you review `.pre-commit-config.yaml`. **GATE**
  - `adr-matrix` — every **Accepted** ADR is cited in the project's feature/status matrix. Keys on ADR
    *status* (per the `docs/adr/README.md` index), not edits, so a hand-maintained `FEATURE-MATRIX.md`
    can't silently drift behind decided designs while Proposed ADRs (roadmap) and typo fixes stay quiet.
    `guardrails-adr-matrix [<adr-index>] [<matrix>]` (auto-discovers both); exempt non-feature decision
    ADRs via `guardrails-adr-exempt.txt` / `$ADR_MATRIX_EXEMPT`. **GATE**
  - `perf-budget` — gate criterion regressions against a checked-in `perf-budgets.toml`. **GATE/NUDGE**
    (CI-deep, not pre-commit: run after `cargo criterion`; gate big regressions, nudge the rest.)
  - `perf-record` — append per-bench medians to a committed `perf-history.csv`. The **PR diff is the
    perf report**; git history is the trend — no external service. Flow:
    `cargo criterion && guardrails-perf-record && guardrails-perf-budget`, then commit the CSV.
    Bespoke (non-criterion) harnesses join via a flat `GUARDRAILS_PERF_RESULTS` JSON map
    (`{"bench_id": value}`) with unit-agnostic `budget` keys and `direction = "higher"` for
    higher-is-better metrics (fps/throughput ceilings — the budget is a floor).
  - + off-the-shelf in `.pre-commit-config.yaml`: gitleaks, rustfmt, clippy `-D warnings`, cargo-deny.
  - Escape hatch on any line: `guardrails-ok`. **`guardrails info`** prints the gates + every config knob.
- **Toolbelt** (`lib.mkDevShell`): `guardrails` (info), prek, gitleaks, cargo-deny, cargo-machete,
  cargo-mutants, cargo-bloat, cargo-criterion, tokei, python3.
- **`checks`**: `nix flake check` runs the gates over this repo.
- **`templates.default`**: a consumer flake + config.
- **Conventions** (`docs/CONVENTIONS.md`): the gate/nudge/CI matrix, the tracing spine (logging
  levels + audit + perf + the agentic-pane trace), the **compile-target 3-tier split** for a lean
  end-product, perf baselines/budgets/methodology, **docs-as-tests** (the how-to *is* the test
  suite — doctests/trycmd/`mdbook test` wired as flake checks, can't-drift), and **ADR lifecycle
  hygiene** (Proposed-until-validated; reconcile supersession seams before flipping to Accepted).
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
