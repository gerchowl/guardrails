# guardrails — conventions (the system, one spine)

Three threads — magic-numbers, logging/audit, perf — are really **one governance system**:
*make the right thing auditable from one surface, hard-gate the high-confidence stuff, nudge the
rest, run deep checks async.* This doc is the contract; `flake.nix` ships the tools/gates.

## Gate / nudge / CI matrix

| Check | Catches (agent failure mode) | Mode |
|---|---|---|
| protect-trunk (+ pre-push twin on the remote ref) | right change, wrong place: direct commit/push to trunk (agents `cd`-ing between clones/worktrees) | **GATE** |
| no-fake-impl (`todo!`/stub/placeholder) | deceptive "done" | **GATE** |
| no-debug-leftovers (`dbg!`/println/console.log) | stdout spew instead of facade | **GATE** |
| no-commented-code | code graveyards | **GATE** |
| derived-docs (marker-driven) | docs drift from generator output | **GATE** |
| adr-matrix (every Accepted ADR cited in the status matrix) | decided designs outrun the feature/status matrix | **GATE** |
| no-conflict-markers | committed merge-conflict debris | **GATE** |
| no-raw-trace-fields (`?`/`%` outside the schema file) | PII/secret leak into the audit JSONL | **GATE** |
| doc-tests (doctest / trycmd / `mdbook test`) | examples & CLI output drift from real behaviour | **CONVENTION** (consumer-wired, see below) |
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
| numerical-obligation ratchet | silent quality regressions on numerical contracts (parity error, coverage %, HARD counts, binary size) — distinct from perf because the *baseline moves on improvement* | **CI-deep + GATE** |

**Rule for adding a check:** it must catch a real *defect class* with a low enough false-positive
rate that nobody reflexively bypasses it. A noisy gate trains `--no-verify` and is worse than none.
Hard-gate deterministic high-confidence; nudge probabilistic/tunable; run slow/deep in CI.

**Avoid (noise traps):** coverage-% targets (gamed → use diff-coverage + mutants), cyclomatic
thresholds, naming/line-length dogma (formatter's job), any *probabilistic* check as a hard gate.

## Soft-gate tiers — when a check runs is a design axis too

Gates have a natural three-tier shape (issue #13): **instant** greps run every commit and need
nothing; **cheap** checks (fmt, config lint, lockfile-scoped deny) can afford every commit or
push; **heavy / calendar-drifting** checks (clippy --all-targets, advisory DBs, full suites)
run at push/CI — and *those* are the ones that go quietly stale. The failure mode is real: an
advisory DB moves on the calendar while the repo sits still, and the gate only wakes when a
big commit finally touches the lockfile. Countermeasure: `guardrails stale` — a stateless
one-shot that compares each gate's last GREEN run (from the #14 trace) against per-gate
`guardrails-stale.toml` thresholds, on BOTH levers (calendar `max_days`, churn
`max_files`/`max_lines`). No daemon, no watcher — delivery reuses the once/week post-push
nudge slot, and richer surfaces (prompt segments, agent hooks) call `guardrails stale --json`
and own their own throttle.

## The escape hatch + the registry pattern

Every gate has a justified escape: annotate the line `guardrails-ok`. But the *better* form for
recurring exceptions is **decorator → generated registry**: mark at the definition site, auto-emit
into one generated, scannable file (can't drift, unlike a hand-maintained allowlist). Generalize it:
- **magic numbers:** `config!(…)` (operator/env-overridable) vs `const_tunable!(…)` (compile-time,
  registered + justified). Both land in a generated `TUNABLES.md` → audit from one file; only the
  first becomes runtime config (so you never expose `workgroup_size` as a nonsense env var).
- same shape for blessed `unwrap`s, dep additions, and `todo!`s: a generated registry per class.

**Adoption on a legacy tree — ratchet, don't triage.** A gate that demands a big-bang cleanup
before it can be wired never gets wired. `no-hardcoded` ships a **baseline ratchet**
(`--record-baseline` → committed `guardrails-baseline.txt`, per-file counts): growth past the
snapshot **hard-fails** (new magic values are gated from day 1), burn-down **nudges** a re-record
(bank the win), at-baseline stays **silent** (no noise for debt you already knew about), and
re-recording **refuses to loosen**. Same shape as flock's DEBT.md census; generalizable to any
count-based gate.

## Docs-as-tests — the how-to *is* the test suite

The strongest can't-drift docs are the ones CI executes. Invert "write docs about the code" into
**"make the docs runnable and run them"**: every copy-pasteable example and every shown CLI output is a
test, so behavioural/API/UX drift **fails the build** instead of rotting silently. This is a
**convention the consumer wires** — guardrails ships no doc-tests gate; each repo adds the layers that
apply to it as its own `flake.nix → checks`, so the **same CI shim** runs them, no new workflow and no
local/CI drift. Three layers:

- **API examples → doctests** (`cargo test --doc`; Python `pytest --doctest-modules` or
  `python -m doctest`). Change a signature and the example stops compiling; change a result and its
  `assert` fails.
- **CLI / UX → `trycmd`/snapbox.** Markdown files of real invocations + expected stdout/stderr/exit,
  diffed against the actual binary. The *walkthrough pages are the acceptance tests*; an output change
  fails the diff (`TRYCMD=overwrite` regenerates in place → you review the diff, which *is* the drift
  report).
- **The book (if the repo has one) → `mdbook test`.** Code blocks in the static how-to are compiled/run;
  the published site is a **byproduct of a green test suite**, never a separately-maintained artifact.

(In this repo only `derived-docs` is wired today; the doctest/trycmd/mdbook layers apply to consumers
with the corresponding surfaces.)

Compose with the **`derived-docs`** gate (generated regions re-run their source command) and you get the
full ladder: generated regions can't drift, examples can't lie, CLI output can't surprise — all under one
`nix flake check`. This is the same move as the tunables registry: retire a hand-maintained surface
(here, prose that *claims* how the tool behaves) for one the machine verifies.

**Honest limit:** this verifies *executable* content — snippets, assertions, shown output — **not prose**.
A wrong explanation around a correct snippet still needs human review; "tested docs" means *the code in
them runs and matches*, not *the narrative is right*. Scaffold it **early** (the first real CLI command is
enough) so UX coverage grows **with** features instead of being retrofitted onto a frozen surface.

## ADR lifecycle hygiene — status integrity, reconcile before flip

The **`adr-matrix`** gate keys on ADR *status*: every **Accepted** ADR must be cited in the project's
feature/status matrix, so decided designs can't silently outrun the matrix while **Proposed** (roadmap)
ADRs and typo fixes stay quiet. Two conventions keep that integrity honest:

- **Proposed until *validated*, not just written.** An ADR carrying a load-bearing parameter (a threshold,
  an overhead, a measured trade-off) stays **Proposed** until a spike measures it; **Accepted** means
  *decided **and** evidenced* (or as-built) — never aspirational. Flipping early turns the matrix into
  fiction the gate then faithfully protects.
- **Reconcile seams *before* flipping; never co-Accept contradictions.** When a later ADR supersedes or
  absorbs an earlier one, record the relationship **explicitly, with a trigger** ("superseded *when X
  ships*") and **scoped** (which clause — not the whole ADR). A superseded design becomes **Superseded**;
  an absorbed one points at its carrier. Two Accepted ADRs must never disagree about the same field, so
  the matrix reflects exactly one truth per feature. (The `adr-matrix` gate does **not** check
  co-Accept contradictions — humans do, at flip time.)

## Fresh-eyes review — author ≠ reviewer, refutation framing

Authors are **confirmation-blind to their own regressions** (observed repeatedly: a retired
concept re-introduced by its own retirer; two implementations of one written spec drifting within
hours; a self-written test exposing the author's just-written bug). The countermeasure is cheap
and procedural:

- **Every landing diff gets a fresh-context pass before merge** — an agent or human who did NOT
  write it, seeded with *refutation framing* ("try to refute that this works"), never "summarize
  this change". A reviewer told to refute reads the escape hatches and gate-config deltas first;
  a reviewer told to look reads the prose and nods.
- **`guardrails diffpack`** emits the full review surface as one artifact: added escape hatches
  and gate-config deltas up top (each is the author requesting an exemption — review those FIRST),
  ADR references in changed hunks (check code against the *decided* design), derived-region edits,
  then the diff, prefixed with the reviewer contract. Pipe it to the fresh context; no other
  setup needed.
- **Cross-impl parity vectors.** When two codebases mirror one contract (protocol types, schema,
  wire format), prose specs WILL drift — within hours, silently. Commit **golden vectors**
  (canonical request/response fixtures, JSON) that BOTH sides must round-trip in their own test
  suites; the fixtures are the contract, the prose is commentary. Same shape as docs-as-tests:
  retire the hand-maintained agreement surface for one the machine verifies.

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

## Local-first gate lifecycle — trunk advances when it's *earned*

The model (issue #18), composed from pieces that each ship separately:

1. **Single-sourced gates.** One gate *definition* feeds every consumer: the same scripts run
   as prek hooks locally AND as `checks.guardrails` in the consumer's flake (the template
   wires it) — so `nix flake check`, and therefore the ci.yml shim, enforces them too. Never
   two *implementations*; the subset per surface may differ by tier (hooks add the
   staged-file/nudge gates; the flake check runs the tree-scannable core).
2. **protect-trunk** (the floor): trunk advances by merge/PR only — the "wrong place" class is
   blocked at commit AND at push (remote-ref keyed).
3. **trunk-merge-gate** (the earned upgrade, solo/trusted-operator repos):
   `GUARDRAILS_TRUNK_MERGE_GATE=1` turns the *push-side* refusal into a pass condition — the
   push to a protected ref is allowed iff `GUARDRAILS_TRUNK_MERGE_CMD` (default
   `nix flake check`) is green *right now*. Pre-push is the honest seam: the commit's own
   hooks already ran, and the flake checks are a superset of the commit tier, so green here
   adds real signal. "Don't commit to main" becomes "commit to main when it's earned."
4. **Runners are for cross-platform release, not enforcement.** Because gates are nix
   derivations, a dev machine and a hosted runner compute the *same* verdict — the runner adds
   storage and platforms, not truth. (Self-reported forge status = follow-up.)

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
