# guardrails — conventions (the system, one spine)

Three threads — magic-numbers, logging/audit, perf — are really **one governance system**:
*make the right thing auditable from one surface, hard-gate the high-confidence stuff, nudge the
rest, run deep checks async.* This doc is the contract; `flake.nix` ships the tools/gates.

## Gate / nudge / CI matrix

| Check | Catches (agent failure mode) | Mode |
|---|---|---|
| no-fake-impl (`todo!`/stub/placeholder) | deceptive "done" | **GATE** |
| no-debug-leftovers (`dbg!`/println/console.log) | stdout spew instead of facade | **GATE** |
| no-commented-code | code graveyards | **GATE** |
| derived-docs (marker-driven) | docs drift from generator output | **GATE** |
| gitleaks | committed secrets | **GATE** |
| rustfmt --check, clippy -D warnings | drift from baseline | **GATE** |
| no-hardcoded-values → tunables registry | magic-number scatter | **GATE** (see below) |
| cargo-deny (licenses + RUSTSEC) | casual/insecure deps | **GATE** |
| cargo-machete | orphan deps | **NUDGE** |
| duplication detector | reinvention vs reuse | **NUDGE** |
| diff blast-radius | scope creep / drive-by edits | **NUDGE** |
| cargo-mutants | test theater (do tests catch bugs?) | **CI-deep** |
| ci-shim (workflow runs logic w/o `nix flake check`) | CI logic that can't run locally; YAML re-derives the build | **NUDGE** (promotable) |
| perf baselines + budgets | silent perf regressions | **CI-deep + GATE on hard** |

**Rule for adding a check:** it must catch a real *defect class* with a low enough false-positive
rate that nobody reflexively bypasses it. A noisy gate trains `--no-verify` and is worse than none.
Hard-gate deterministic high-confidence; nudge probabilistic/tunable; run slow/deep in CI.

**Avoid (noise traps):** coverage-% targets (gamed → use diff-coverage + mutants), cyclomatic
thresholds, naming/line-length dogma (formatter's job), any *probabilistic* check as a hard gate.

## The escape hatch + the registry pattern

Every gate has a justified escape: annotate the line `guardrails-ok`. But the *better* form for
recurring exceptions is **decorator → generated registry**: mark at the definition site, auto-emit
into one generated, scannable file (can't drift, unlike a hand-maintained allowlist). Generalize it:
- **magic numbers:** `config!(…)` (operator/env-overridable) vs `const_tunable!(…)` (compile-time,
  registered + justified). Both land in a generated `TUNABLES.md` → audit from one file; only the
  first becomes runtime config (so you never expose `workgroup_size` as a nonsense env var).
- same shape for blessed `unwrap`s, dep additions, and `todo!`s: a generated registry per class.

## Logging / tracing — one spine, four payoffs

Use **`tracing` + `tracing-subscriber` (`EnvFilter`)**, structured fields. The same spine serves
**debug · perf attribution · governance audit · the product's trace feature** — build it once.

Level contract (the one rule agents break: **frequency dictates level**):
- **error** — an op/invariant *failed*, actionable.
- **warn** — degraded but recovered (fallback/retry/cap hit).
- **info** — *low-frequency* lifecycle/operational events (startup, config loaded, worker started).
  **Never per-iteration.**
- **debug** — developer diagnosis (decisions, counts).
- **trace** — firehose: per-frame/-message/-item; spans + timings.

A `tracing` *layer* writing structured JSONL locally **is** the audit trail and the agentic-pane's
"full traces" — same mechanism, capability-gated.

Because that JSONL **is** the audit surface, every logged field must be *deliberately shaped*: never
`info!(?value)` / `warn!(%value)` (raw `Debug`/`Display` of a whole value — the reflexive way PII or
secrets leak in). Confine raw `?`/`%` formatting to the one schema/redaction file where fields are
defined and paths are redacted; the `no-raw-trace-fields` **GATE** enforces the boundary
(allowlist that file via `GUARDRAILS_TRACE_ALLOW_GLOBS`).

## Compile targets — leaner end-product (THE three-tier split)

Yes, gate by build profile — but only **Tier 1** is compiled out. Conflating these is the mistake:

- **Tier 1 — dev-only diagnostics → COMPILE OUT / feature-gate (lean release):**
  - `debug!`/`trace!` → `tracing/release_max_level_info` (or `_warn`) **statically removes those
    call sites** in release: zero cost, smaller binary. Keep info/warn/error.
  - perf instrumentation (spans, GPU timestamp queries, the fps/frame HUD, `wgpu-profiler`) behind a
    `profiling` cargo feature, **off by default**.
  - alloc tracking (`dhat`/`stats_alloc` global allocator) behind a `dhat` feature, dev/bench only.
  - expensive invariant checks → `debug_assert!` (free in release, built-in).
- **Tier 2 — production observability → SHIPS, never compiled out:** info/warn/error tracing,
  structured, runtime-filtered (`EnvFilter`/`RUST_LOG`). You want this in the field; idle cost is
  ~nil (disabled-level checks are static).
- **Tier 3 — product features on the same spine → SHIP as runtime/capability-gated features:** the
  agentic-pane trace / audit log. It's *product*, not diagnostics — gate it at runtime (user opt-in),
  not at compile time.

Lean-release profile (bundle as a convention + `cargo-bloat` in the toolbelt to inspect):
```toml
[profile.release]
opt-level = 3
lto = "thin"          # or "fat" for max; slower build
codegen-units = 1
strip = true
# panic = "abort"     # smaller/faster, but loses unwinding — opt-in per app
```
And `features = { profiling = [...]; dhat = [...]; }`, default `[]` → diagnostics off in the
shipped artifact, on in dev/bench. One codebase, lean product, full dev visibility.

## Perf — measured, baselined, attributable from day 1

The non-retrofittable part is **baseline + history**: capture from commit 1 or "it got slow" is
forever unattributable.
- microbenches: `criterion` (statistical baselines); track history in CI via **CodSpeed**
  (instruction-count sandbox → immune to runner noise) or Bencher.
- macro/throughput harnesses live in-repo (e.g. headless GPU/parsing benches).
- attribution rides the tracing spine: spans → `tracing-flame`/`tracing-chrome`; GPU passes via
  timestamp queries / `wgpu-profiler`.
- a checked-in **perf-budgets** file → CI compares; **gate** big regressions (>~15–20% on a
  value-path metric), **nudge** the rest.
- **honest measurement:** measure GPU/CPU time *uncapped* (not vsync-capped fps); use
  ratio/statistical comparison on noisy hardware; flag software-vs-real-GPU and harness caps. Wrong
  methodology bakes in confidently-wrong baselines — worse than none.

## CI = a shim over a local-runnable check

**The logic lives in `nix flake check`; the workflow only triggers it.** One definition runs
identically on a dev's machine and in CI — there is no "passes locally / fails in CI" drift because
it is the *same* command. The `.github/workflows/*.yml` is a shim: checkout → install nix →
`nix flake check -L`. No project logic in YAML; nothing to reproduce by hand.

```yaml
# the entire CI job — see templates/default/ci.yml
runs-on: ubuntu-latest            # the ONLY public/private difference (see below)
steps:
  - uses: actions/checkout@v4
  - uses: DeterminateSystems/nix-installer-action@main
  - run: nix flake check -L
```

**The runner is interchangeable.** Because the shim carries no logic, the only thing that differs
between repos is the one `runs-on:` line:

| Origin | `runs-on` | Why |
|---|---|---|
| **public** repo | `ubuntu-latest` / `macos-latest` (GitHub-hosted) | a public repo accepts PRs from anyone — running that on your own hardware is arbitrary code execution. **Never.** |
| **private** repo | `[self-hosted, <label>]` (e.g. anvil/sage) | trusted collaborators only; org-scoped runners cover every private repo in the org |

So "GitHub-hosted vs self-hosted vs mirror" stops being an architecture question and collapses to a
label. **Self-hosted runners are private-repos-only** — enforced by the runner group's
`allows_public_repositories = false`. They are **outbound-only** (long-poll *out* to the forge; no
inbound endpoint, no ingress, registration token short-lived + uncommitted). Mirroring a public repo
into a private one to "borrow" self-hosted runners is a **backdoor** that launders untrusted code
onto your hardware — don't.

**What stays OUT of the shim.** `nix flake check` is for the deterministic, hermetic core
(build, lint, fmt, unit/integration tests, generated-doc checks). Host-bound / non-deterministic
jobs — browser e2e, platform bundling (macOS/Windows), GPU/perf harnesses — are *not* flake-check
material; they live as their own explicit (usually GitHub-hosted) jobs. Don't force them into the
shim, and don't let them become the excuse to put *all* logic back in YAML.

**Rule:** if a check is reproducible, it goes in `flake.nix → checks` (run-local + CI, one
definition); the workflow only ever *invokes* it. A consumer's `flake.nix` therefore must define
`checks`; `templates/default/` ships the `ci.yml` shim + a `checks` stub to copy.
