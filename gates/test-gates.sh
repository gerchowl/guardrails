#!/usr/bin/env bash
# Red-green tests for the guardrails gate scripts. Pure bash, no deps.
# Run: gates/test-gates.sh   (also wired into CI via `nix flake check` is the
# gate self-check; this harness asserts catch/allow semantics on fixtures.)
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
debug_gate="$here/no-debug-leftovers.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0

# assert <desc> <want-exit> <env-assignments...> -- <file>
#   runs the debug gate on <file> with any leading VAR=val env, asserts exit code.
assert() {
  local desc="$1" want="$2"; shift 2
  local env=()
  while [ "$1" != "--" ]; do env+=("$1"); shift; done
  shift
  env "${env[@]}" "$debug_gate" "$1" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$want" ]; then
    echo "ok    — $desc"
  else
    echo "FAIL  — $desc (want exit $want, got $got)"
    fails=$((fails + 1))
  fi
}

mkdir -p "$tmp/src/cli"

# --- caught in library code (exit 1) -----------------------------------------
# print!/eprint! were previously UNCAUGHT — these are the red→green cases.
for macro in 'dbg!(x)' 'print!("x")' 'println!("x")' 'eprint!("x")' 'eprintln!("x")'; do
  name="$(printf '%s' "$macro" | tr -cd 'a-z')"
  printf 'fn f() { %s; }\n' "$macro" > "$tmp/src/leak_$name.rs"
  assert "library $macro is flagged" 1 -- "$tmp/src/leak_$name.rs"
done

# --- allowed surfaces (exit 0) ------------------------------------------------
printf 'fn main() { println!("hi"); print!("p"); }\n' > "$tmp/src/main.rs"
assert "main.rs is allowed" 0 -- "$tmp/src/main.rs"

# build.rs legitimately uses println! for cargo: directives.
printf 'fn main() { println!("cargo:rerun-if-changed=build.rs"); }\n' > "$tmp/build.rs"
assert "build.rs is allowed" 0 -- "$tmp/build.rs"

printf 'pub fn show() { println!("status"); }\n' > "$tmp/src/cli/show.rs"
assert "cli/ flagged WITHOUT output-glob" 1 -- "$tmp/src/cli/show.rs"
assert "cli/ allowed WITH GUARDRAILS_OUTPUT_GLOBS" 0 \
  "GUARDRAILS_OUTPUT_GLOBS=*/cli/*" -- "$tmp/src/cli/show.rs"

printf 'fn f() { println!("x"); } // guardrails-ok\n' > "$tmp/src/annotated.rs"
assert "guardrails-ok annotation suppresses" 0 -- "$tmp/src/annotated.rs"

# --- no false positive on innocuous code -------------------------------------
printf 'fn f() -> u32 { 1 + 1 }\n' > "$tmp/src/clean.rs"
assert "clean code passes" 0 -- "$tmp/src/clean.rs"

# --- no-fake-impl: stub markers flagged, vocabulary/strings are not ----------
fake_gate="$here/no-fake-impl.sh"
fake_assert() { # desc, want-exit, file-content
  printf '%s\n' "$3" > "$tmp/src/fake.rs"
  "$fake_gate" "$tmp/src/fake.rs" >/dev/null 2>&1
  if [ "$?" = "$2" ]; then echo "ok    — $1"; else echo "FAIL  — $1"; fails=$((fails + 1)); fi
}
fake_assert "todo!() is flagged"                    1 'fn f() { todo!() }'
fake_assert "unimplemented!() is flagged"           1 'fn f() { unimplemented!() }'
fake_assert "FIXME marker is flagged"               1 'fn f() {} // FIXME finish this'
fake_assert "// placeholder comment is flagged"     1 'fn f() {} // placeholder'
fake_assert "placeholder implementation is flagged" 1 '// placeholder implementation for now'
fake_assert "PLACEHOLDER protocol const is allowed" 0 'const KITTY_UNICODE_PLACEHOLDER: u32 = 0xfffd;'
fake_assert "placeholder sentinel var is allowed"   0 'let placeholder = PaneId::from_raw(0);'
fake_assert "not-implemented error string allowed"  0 'return Err("method not implemented yet".into());'
fake_assert "placeholder in doc-comment prose ok"   0 '/// Uses the placeholder protocol to render.'
fake_assert "doc comment starting with placeholder prose ok" 0 '///   placeholder and other things are kept'

# --- top-level tests/ excluded for RELATIVE paths (as pre-commit passes them) -
# `*/tests/*` matched only NESTED tests dirs; a relative `tests/x.rs` slipped
# through. Each gate must exclude a top-level tests/ component too.
mkdir -p "$tmp/tests"
printf 'fn f() { eprintln!("x"); todo!(); } // %s\n' 'commented: let x = 1;' > "$tmp/tests/leak.rs"
for gate in no-debug-leftovers no-fake-impl no-commented-code; do
  ( cd "$tmp" && "$here/$gate.sh" tests/leak.rs >/dev/null 2>&1 )
  if [ $? = 0 ]; then echo "ok    — $gate excludes top-level tests/ (relative)"
  else echo "FAIL  — $gate flags top-level tests/ (relative)"; fails=$((fails + 1)); fi
done

# --- perf-budget gate ---------------------------------------------------------
# Synthesize criterion estimates + budgets; assert gate/nudge/skip semantics.
perf_gate="$here/perf-budget.sh"
pdir="$tmp/perf"
mkdir -p "$pdir/crit/grp/fast/new" "$pdir/crit/grp/slow/new"
printf '{"median":{"point_estimate":900.0}}\n'  > "$pdir/crit/grp/fast/new/estimates.json"  # under
printf '{"median":{"point_estimate":1500.0}}\n' > "$pdir/crit/grp/slow/new/estimates.json"  # over 1000+20%

perf_assert() { # desc, want-exit, budgets-file
  "$perf_gate" "$3" "$pdir/crit" >/dev/null 2>&1
  if [ "$?" = "$2" ]; then echo "ok    — $1"; else echo "FAIL  — $1"; fails=$((fails + 1)); fi
}
printf 'default_tolerance=0.20\n[bench."grp/fast"]\nbudget_ns=1000\nmode="gate"\n'  > "$pdir/under.toml"
printf 'default_tolerance=0.20\n[bench."grp/slow"]\nbudget_ns=1000\nmode="gate"\n'  > "$pdir/gate.toml"
printf 'default_tolerance=0.20\n[bench."grp/slow"]\nbudget_ns=1000\nmode="nudge"\n' > "$pdir/nudge.toml"
perf_assert "perf-budget passes under budget"            0 "$pdir/under.toml"
perf_assert "perf-budget gates an over-budget regression" 1 "$pdir/gate.toml"
perf_assert "perf-budget nudge mode warns, never blocks"  0 "$pdir/nudge.toml"
perf_assert "perf-budget skips when no budgets file"      0 "$pdir/missing.toml"

# --- perf-record: append CSV rows, track vs-prev across commits ----------------
rec="$here/perf-record.sh"
rcsv="$pdir/history.csv"
check_csv() { # desc, grep-pattern
  if grep -q "$2" "$rcsv"; then echo "ok    — $1"; else echo "FAIL  — $1 (no '$2' in csv)"; fails=$((fails + 1)); fi
}
GUARDRAILS_PERF_COMMIT=aaa1 GUARDRAILS_PERF_DATE=D1 "$rec" "$rcsv" "$pdir/under.toml" "$pdir/crit" >/dev/null 2>&1
check_csv "perf-record writes a header" '^date,commit,bench'
check_csv "perf-record records median + budget (under)" 'aaa1,grp/fast,900,1000,-10.0,'
check_csv "perf-record records un-budgeted bench too"   'aaa1,grp/slow,1500,,,'
# second commit, bump grp/fast 900 -> 1080: vs_prev = +20.0%, vs_budget(1000) = +8.0%
printf '{"median":{"point_estimate":1080.0}}\n' > "$pdir/crit/grp/fast/new/estimates.json"
GUARDRAILS_PERF_COMMIT=bbb2 GUARDRAILS_PERF_DATE=D2 "$rec" "$rcsv" "$pdir/under.toml" "$pdir/crit" >/dev/null 2>&1
check_csv "perf-record tracks vs_prev across commits" 'bbb2,grp/fast,1080,1000,+8.0,+20.0'
# re-run on same commit refreshes (not duplicates) its rows
GUARDRAILS_PERF_COMMIT=bbb2 GUARDRAILS_PERF_DATE=D3 "$rec" "$rcsv" "$pdir/under.toml" "$pdir/crit" >/dev/null 2>&1
if [ "$(grep -c 'bbb2,grp/fast,' "$rcsv")" = 1 ]; then echo "ok    — perf-record dedups rows per commit"
else echo "FAIL  — perf-record duplicated rows for a commit"; fails=$((fails + 1)); fi

# --- perf: bespoke results map + higher-is-better budgets --------------------------
# A GPU fps-ceiling style metric: budget is a FLOOR, results come from a JSON map (no criterion).
printf '{"gpu/ceiling": 850000, "gpu/fast": 1300000}\n' > "$pdir/results.json"  # 850k < 1M floor −10%
printf '[bench."gpu/ceiling"]\nbudget=1000000\nmode="gate"\ndirection="higher"\ntolerance=0.10\n' > "$pdir/floor-bad.toml"
printf '[bench."gpu/fast"]\nbudget=1000000\nmode="gate"\ndirection="higher"\ntolerance=0.10\n' > "$pdir/floor-good.toml"
GUARDRAILS_PERF_RESULTS="$pdir/results.json" "$perf_gate" "$pdir/floor-bad.toml" "$pdir/crit" >/dev/null 2>&1
if [ $? = 1 ]; then echo "ok    — perf-budget gates a higher-is-better metric below its floor"
else echo "FAIL  — higher-direction floor not gated"; fails=$((fails + 1)); fi
GUARDRAILS_PERF_RESULTS="$pdir/results.json" "$perf_gate" "$pdir/floor-good.toml" "$pdir/crit" >/dev/null 2>&1
if [ $? = 0 ]; then echo "ok    — perf-budget passes a higher-is-better metric above its floor"
else echo "FAIL  — higher-direction pass case failed"; fails=$((fails + 1)); fi
GUARDRAILS_PERF_RESULTS="$pdir/results.json" GUARDRAILS_PERF_COMMIT=ccc3 GUARDRAILS_PERF_DATE=D4 \
  "$rec" "$rcsv" "$pdir/floor-good.toml" "$pdir/crit" >/dev/null 2>&1
check_csv "perf-record ingests bespoke results too" 'ccc3,gpu/ceiling,850000,,'

# --- no-hardcoded: token-level floats, underscores, paths-in-strings, env prefixes ---
hard_gate="$here/no-hardcoded.sh"
hard_assert() { # desc, want-exit, env(or --), file-content
  local desc="$1" want="$2"; shift 2
  local env=()
  while [ "$1" != "--" ]; do env+=("$1"); shift; done
  shift
  printf '%s\n' "$1" > "$tmp/src/hard.rs"
  env "${env[@]}" "$hard_gate" "$tmp/src/hard.rs" >/dev/null 2>&1
  if [ "$?" = "$want" ]; then echo "ok    — $desc"; else echo "FAIL  — $desc"; fails=$((fails + 1)); fi
}
hard_assert "bad float flagged even with allowed 0.0 on the line" 1 -- 'let a = 0.0; let b = 3.7;'
hard_assert "allowed floats pass (0.0/0.5/1.0/2.0)"               0 -- 'let a = 0.0 + 0.5 * 1.0 - 2.0;'
hard_assert "underscored int 100_000 is flagged"                  1 -- 'let n = 100_000;'
hard_assert "int below 100 passes"                                0 -- 'let n = 99;'
hard_assert "/tmp/ path INSIDE a string literal is flagged"       1 -- 'let p = "/tmp/scratch.sock";'
hard_assert "/Users/ path inside a string literal is flagged"     1 -- 'let p = "/Users/me/x";'
hard_assert "env-prefix literal flagged when knob set"            1 "GUARDRAILS_ENV_PREFIXES=MYAPP_:OTHER_" -- 'std::env::var("MYAPP_MODE")'
hard_assert "env-prefix check off by default"                     0 -- 'std::env::var("MYAPP_MODE")'
hard_assert "hardcode-ok line escape works"                       0 -- 'let b = 3.7; // hardcode-ok: feel'
hard_assert "const_tunable! line is the sanctioned home"          0 -- 'const_tunable!(G: f32 = 9.81, "gravity");'
hard_assert "guardrails-ok-begin/end block escape works"          0 -- '// guardrails-ok-begin: mesh
let v = [1.5, 2.7, 300.0];
// guardrails-ok-end'
hard_assert "digits inside strings are not values"                0 -- 'let s = "0123456789 and 3.14159";'

# --- no-conflict-markers: committed markers are flagged; setext headings are not ---
cm_gate="$here/no-conflict-markers.sh"
cm_assert() { # desc, want-exit, file
  "$cm_gate" "$1" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$2" ]; then echo "ok    — $3"; else echo "FAIL  — $3 (want $2, got $got)"; fails=$((fails + 1)); fi
}
printf '%s\n' 'fn x() {}' '<<<<<<< HEAD' 'a' '=======' 'b' '>>>>>>> other' > "$tmp/conflicted.rs"
cm_assert "$tmp/conflicted.rs" 1 "committed conflict markers are flagged"
printf '%s\n' 'Title' '=======' '' 'prose' > "$tmp/setext.md"
cm_assert "$tmp/setext.md" 0 "setext ======= heading alone is allowed"
printf '%s\n' 'clean file' > "$tmp/clean.txt"
cm_assert "$tmp/clean.txt" 0 "clean file passes"

# --- derived-docs: regions match cmd output; --fix regenerates; bad markers error ---
dd_gate="$here/derived-docs.sh"
dd_assert() { # desc, want-exit, file, [--fix?]
  local desc="$1" want="$2" file="$3" flag="${4:-}"
  if [ -n "$flag" ]; then "$dd_gate" "$flag" "$file" >/dev/null 2>&1; else "$dd_gate" "$file" >/dev/null 2>&1; fi
  local got=$?
  if [ "$got" = "$want" ]; then echo "ok    — $desc"
  else echo "FAIL  — $desc (want $want, got $got)"; fails=$((fails + 1)); fi
}
# matching region → pass
printf '%s\n' '# t' '<!-- guardrails:derived cmd="echo hello" -->' 'hello' '<!-- guardrails:derived:end -->' \
  > "$tmp/dd-match.md"
dd_assert "derived-docs passes when region matches" 0 "$tmp/dd-match.md"
# drifted region → fail
printf '%s\n' '# t' '<!-- guardrails:derived cmd="echo hello" -->' 'goodbye' '<!-- guardrails:derived:end -->' \
  > "$tmp/dd-drift.md"
dd_assert "derived-docs flags drifted region" 1 "$tmp/dd-drift.md"
# --fix roundtrip → idempotent pass after
dd_assert "derived-docs --fix exits 0" 0 "$tmp/dd-drift.md" --fix
dd_assert "derived-docs passes after --fix" 0 "$tmp/dd-drift.md"
if ! grep -q '^hello$' "$tmp/dd-drift.md"; then
  echo "FAIL  — derived-docs --fix did not rewrite body"; fails=$((fails + 1))
else echo "ok    — derived-docs --fix rewrites the region body"; fi
# unterminated → marker error
printf '%s\n' '<!-- guardrails:derived cmd="echo x" -->' 'orphan' > "$tmp/dd-unterm.md"
dd_assert "derived-docs errors on unterminated region" 1 "$tmp/dd-unterm.md"
# nested → marker error
printf '%s\n' '<!-- guardrails:derived cmd="echo x" -->' '<!-- guardrails:derived cmd="echo y" -->' \
  'y' '<!-- guardrails:derived:end -->' > "$tmp/dd-nested.md"
dd_assert "derived-docs errors on nested start markers" 1 "$tmp/dd-nested.md"
# stray :end → marker error
printf '%s\n' 'prose' '<!-- guardrails:derived:end -->' > "$tmp/dd-stray.md"
dd_assert "derived-docs errors on stray :end" 1 "$tmp/dd-stray.md"
# failing command → marker error (regions whose cmd doesn't exist can't be diffed)
printf '%s\n' '<!-- guardrails:derived cmd="nonexistent-binary-xyzzy" -->' 'x' \
  '<!-- guardrails:derived:end -->' > "$tmp/dd-cmdfail.md"
dd_assert "derived-docs errors when cmd fails to run" 1 "$tmp/dd-cmdfail.md"
# multiple regions, one drifted → fail; --fix fixes only the drifted one
printf '%s\n' '<!-- guardrails:derived cmd="echo one" -->' 'one' '<!-- guardrails:derived:end -->' \
  '' '<!-- guardrails:derived cmd="echo two" -->' 'TWO' '<!-- guardrails:derived:end -->' \
  > "$tmp/dd-multi.md"
dd_assert "derived-docs flags one drifted of two regions" 1 "$tmp/dd-multi.md"
dd_assert "derived-docs --fix repairs multi-region file"  0 "$tmp/dd-multi.md" --fix
dd_assert "derived-docs passes after multi-region fix"    0 "$tmp/dd-multi.md"
# file without any markers → no work, pass
printf '%s\n' 'plain prose with no markers at all' > "$tmp/dd-none.md"
dd_assert "derived-docs ignores files without markers" 0 "$tmp/dd-none.md"

# --- ci-shim gate ------------------------------------------------------------
ci_gate="$here/ci-shim.sh"
mkdir -p "$tmp/.github/workflows"
# a shim (invokes a nix check) → clean (no output, exit 0)
printf 'jobs:\n  check:\n    runs-on: ubuntu-latest\n    steps:\n      - run: nix flake check -L\n' \
  > "$tmp/.github/workflows/shim.yml"
out="$("$ci_gate" "$tmp/.github/workflows/shim.yml" 2>&1)"
[ -z "$out" ] && echo "ci-shim ok    — shim workflow passes clean" \
  || { echo "ci-shim FAIL  — shim flagged: $out"; fails=$((fails + 1)); }
# logic, no nix check → nudged (names the file), but exit 0 by default
printf 'jobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: cargo build --release\n' \
  > "$tmp/.github/workflows/logic.yml"
out="$("$ci_gate" "$tmp/.github/workflows/logic.yml" 2>&1)"
printf '%s' "$out" | grep -q 'logic.yml' && echo "ci-shim ok    — logic-only workflow nudged" \
  || { echo "ci-shim FAIL  — logic-only not nudged"; fails=$((fails + 1)); }
"$ci_gate" "$tmp/.github/workflows/logic.yml" >/dev/null 2>&1 \
  && echo "ci-shim ok    — nudge exits 0 by default" \
  || { echo "ci-shim FAIL  — default nudge should exit 0"; fails=$((fails + 1)); }
# guardrails-ok in the file → allowlisted
printf '# guardrails-ok: host-bound e2e\njobs:\n  e2e:\n    steps:\n      - run: npx playwright test\n' \
  > "$tmp/.github/workflows/e2e.yml"
out="$("$ci_gate" "$tmp/.github/workflows/e2e.yml" 2>&1)"
[ -z "$out" ] && echo "ci-shim ok    — guardrails-ok allowlists the workflow" \
  || { echo "ci-shim FAIL  — allowlist ignored: $out"; fails=$((fails + 1)); }
# enforce mode → hard fail (exit 1) on a logic-only workflow
if GUARDRAILS_CI_SHIM_ENFORCE=1 "$ci_gate" "$tmp/.github/workflows/logic.yml" >/dev/null 2>&1; then
  echo "ci-shim FAIL  — enforce mode should exit 1"; fails=$((fails + 1))
else
  echo "ci-shim ok    — enforce mode exits 1"
fi

# --- no-raw-trace-fields: ?/% Debug/Display field formatters in tracing macros ------
trace_gate="$here/no-raw-trace-fields.sh"
trace_assert() { # desc, want-exit, env(or --), file-content
  local desc="$1" want="$2"; shift 2
  local env=()
  while [ "$1" != "--" ]; do env+=("$1"); shift; done
  shift
  printf '%s\n' "$1" > "$tmp/src/trace.rs"
  env "${env[@]}" "$trace_gate" "$tmp/src/trace.rs" >/dev/null 2>&1
  if [ "$?" = "$want" ]; then echo "ok    — $desc"; else echo "FAIL  — $desc"; fails=$((fails + 1)); fi
}
trace_assert "info!(name = ?val) is flagged"             1 -- 'fn f() { info!(user = ?user); }'
trace_assert "debug!(%val) shorthand is flagged"         1 -- 'fn f() { debug!(%peer); }'
trace_assert "error!(?val, msg) shorthand is flagged"    1 -- 'fn f() { error!(?e, "boom"); }'
trace_assert "tracing::warn!(x = ?y) qualified flagged"  1 -- 'fn f() { tracing::warn!(req = ?req); }'
trace_assert "multi-line field formatter is flagged"     1 -- 'fn f() {
    info!(
        user = ?user,
    );
}'
trace_assert "modulo a % b is not a formatter"           0 -- 'fn f() -> u32 { a % 4 }'
trace_assert "try operator foo()? is not a formatter"    0 -- 'fn f() { let x = foo()?; }'
trace_assert "match arm => is not a field assignment"    0 -- 'fn f() { match e { _ => err() } }'
trace_assert "plain message string passes"               0 -- 'fn f() { info!("done {}", n); }'
trace_assert "regex inline flags r\"(?i)\" not flagged"  0 -- 'fn f() { Regex::new(r"(?i)x(?:y)(?P<n>z)"); }'
trace_assert "percent inside a message string passes"    0 -- 'fn f() { info!(pct = p, "{}% done", p); }'
trace_assert "guardrails-ok suppresses"                  0 -- 'fn f() { info!(?e); } // guardrails-ok'
trace_assert "allowlisted schema surface is skipped"     0 \
  "GUARDRAILS_TRACE_ALLOW_GLOBS=*/src/trace.rs" -- 'fn f() { info!(user = ?user); }'
# tests/ path is exempt even for a real formatter (relative path, as pre-commit passes it)
printf 'fn f() { info!(user = ?user); }\n' > "$tmp/tests/trace_leak.rs"
( cd "$tmp" && "$trace_gate" tests/trace_leak.rs >/dev/null 2>&1 )
if [ $? = 0 ]; then echo "ok    — no-raw-trace-fields excludes top-level tests/ (relative)"
else echo "FAIL  — no-raw-trace-fields flags top-level tests/ (relative)"; fails=$((fails + 1)); fi

# --- numerical-obligation: ratcheting baselines vs measurement JSON --------------
# Verifies: regression gated, improvement ratchets the baseline on --update (never widens
# slack), tolerance honored, higher-is-better direction works, missing measurement is a
# soft-skip, nudge mode warns but passes, ratchet=false freezes baseline as a fixed budget.
numob_gate="$here/numerical-obligation.sh"
ndir="$tmp/numob"
mkdir -p "$ndir"

numob_assert() { # desc, want-exit, args...
  local desc="$1" want="$2"; shift 2
  "$numob_gate" "$@" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$want" ]; then echo "ok    — $desc"
  else echo "FAIL  — $desc (want $want, got $got)"; fails=$((fails + 1)); fi
}

# (1) Lower-is-better: regression beyond zero tolerance is gated.
printf '{"adapters":{"foo":{"hard":10}}}\n' > "$ndir/base.json"
printf '{"adapters":{"foo":{"hard":11}}}\n' > "$ndir/meas.json"
cat > "$ndir/regress.toml" <<EOF
[set."t"]
baseline = "$ndir/base.json"
measurement = "$ndir/meas.json"
EOF
numob_assert "regression beyond tolerance is gated" 1 "$ndir/regress.toml"

# (2) Same regression, nudge mode: warns but exit 0.
cat > "$ndir/nudge.toml" <<EOF
default_mode = "nudge"
[set."t"]
baseline = "$ndir/base.json"
measurement = "$ndir/meas.json"
EOF
numob_assert "regression in nudge mode warns but passes" 0 "$ndir/nudge.toml"

# (3) Within tolerance: 11 vs 10 with 20% tolerance allows up to 12.
cat > "$ndir/within.toml" <<EOF
default_tolerance = 0.20
[set."t"]
baseline = "$ndir/base.json"
measurement = "$ndir/meas.json"
EOF
numob_assert "within tolerance passes" 0 "$ndir/within.toml"

# (4) Improvement: 10 → 9 under default direction (lower). Check passes; --update ratchets.
printf '{"adapters":{"foo":{"hard":10}}}\n' > "$ndir/base.json"
printf '{"adapters":{"foo":{"hard":9}}}\n'  > "$ndir/meas.json"
cat > "$ndir/improve.toml" <<EOF
[set."t"]
baseline = "$ndir/base.json"
measurement = "$ndir/meas.json"
EOF
numob_assert "improvement passes check" 0 "$ndir/improve.toml"
"$numob_gate" --update "$ndir/improve.toml" >/dev/null 2>&1
new_val=$(python3 -c 'import json; print(json.load(open("'"$ndir"'/base.json"))["adapters"]["foo"]["hard"])')
if [ "$new_val" = "9" ]; then echo "ok    — --update ratchets baseline DOWN to improvement"
else echo "FAIL  — --update did not ratchet (baseline=$new_val, expected 9)"; fails=$((fails + 1)); fi

# (5) After --update, a fresh measurement at the old level is now a regression.
printf '{"adapters":{"foo":{"hard":10}}}\n' > "$ndir/meas.json"
numob_assert "regression vs newly-ratcheted baseline is gated" 1 "$ndir/improve.toml"

# (6) --update on a regression does NOT widen the baseline (ratchet, not budget).
printf '{"adapters":{"foo":{"hard":9}}}\n'  > "$ndir/base.json"
printf '{"adapters":{"foo":{"hard":20}}}\n' > "$ndir/meas.json"
"$numob_gate" --update "$ndir/improve.toml" >/dev/null 2>&1
val=$(python3 -c 'import json; print(json.load(open("'"$ndir"'/base.json"))["adapters"]["foo"]["hard"])')
if [ "$val" = "9" ]; then echo "ok    — --update REFUSES to widen on regression"
else echo "FAIL  — --update widened baseline 9 → $val"; fails=$((fails + 1)); fi

# (7) Higher-is-better: throughput floor with tolerance.
printf '{"throughput":1000}\n' > "$ndir/base.json"
printf '{"throughput":850}\n'  > "$ndir/meas.json"
cat > "$ndir/higher-bad.toml" <<EOF
default_direction = "higher"
default_tolerance = 0.10
[set."t"]
baseline = "$ndir/base.json"
measurement = "$ndir/meas.json"
EOF
numob_assert "higher-direction floor gated when below" 1 "$ndir/higher-bad.toml"
printf '{"throughput":950}\n' > "$ndir/meas.json"
numob_assert "higher-direction within tolerance passes" 0 "$ndir/higher-bad.toml"

# (8) Higher-is-better improvement also ratchets UP on --update.
printf '{"throughput":1500}\n' > "$ndir/meas.json"
"$numob_gate" --update "$ndir/higher-bad.toml" >/dev/null 2>&1
val=$(python3 -c 'import json; print(json.load(open("'"$ndir"'/base.json"))["throughput"])')
if [ "$val" = "1500" ]; then echo "ok    — --update ratchets higher-direction baseline UP"
else echo "FAIL  — higher-direction --update did not ratchet (baseline=$val)"; fails=$((fails + 1)); fi

# (9) Missing measurement: soft-skip (warn, exit 0).
printf '{"a":1}\n' > "$ndir/base.json"
rm -f "$ndir/meas.json"
cat > "$ndir/missing-meas.toml" <<EOF
[set."t"]
baseline = "$ndir/base.json"
measurement = "$ndir/missing.json"
EOF
numob_assert "missing measurement file is a soft-skip" 0 "$ndir/missing-meas.toml"

# (10) Missing baseline: hard error.
cat > "$ndir/missing-base.toml" <<EOF
[set."t"]
baseline = "$ndir/no-such.json"
measurement = "$ndir/base.json"
EOF
numob_assert "missing baseline file is a hard error" 1 "$ndir/missing-base.toml"

# (11) Missing config file: soft-skip (opt-in by file presence, matches perf-budget UX).
numob_assert "missing config is a soft-skip" 0 "$ndir/no-such-config.toml"

# (12) ratchet=false: --update does NOT modify even on improvement (it's a fixed budget).
printf '{"a":10}\n' > "$ndir/base.json"
printf '{"a":5}\n'  > "$ndir/meas.json"
cat > "$ndir/fixed.toml" <<EOF
[set."t"]
baseline = "$ndir/base.json"
measurement = "$ndir/meas.json"
ratchet = false
EOF
"$numob_gate" --update "$ndir/fixed.toml" >/dev/null 2>&1
val=$(python3 -c 'import json; print(json.load(open("'"$ndir"'/base.json"))["a"])')
if [ "$val" = "10" ]; then echo "ok    — ratchet=false treats baseline as a fixed budget"
else echo "FAIL  — ratchet=false was ratcheted (baseline=$val, expected 10)"; fails=$((fails + 1)); fi

# (13) Nested + multi-key: every numeric leaf is independently gated.
printf '{"col":{"A":{"x":1.0,"y":2.0},"B":{"x":3.0}}}\n' > "$ndir/base.json"
printf '{"col":{"A":{"x":1.1,"y":1.9},"B":{"x":3.5}}}\n' > "$ndir/meas.json"
cat > "$ndir/nested.toml" <<EOF
[set."t"]
baseline = "$ndir/base.json"
measurement = "$ndir/meas.json"
EOF
"$numob_gate" "$ndir/nested.toml" >/dev/null 2>&1
if [ $? = 1 ]; then echo "ok    — nested leaves are independently gated"
else echo "FAIL  — nested gating wrong"; fails=$((fails + 1)); fi

# (14) ${ENV:-default} expansion in measurement paths.
printf '{"a":1}\n' > "$ndir/base.json"
printf '{"a":1}\n' > "$ndir/env-meas.json"
cat > "$ndir/env.toml" <<EOF
[set."t"]
baseline = "$ndir/base.json"
measurement = "\${NUMOB_TEST_MEAS:-$ndir/env-meas.json}"
EOF
NUMOB_TEST_MEAS="$ndir/env-meas.json" "$numob_gate" "$ndir/env.toml" >/dev/null 2>&1
if [ $? = 0 ]; then echo "ok    — \${ENV:-default} expansion in measurement path"
else echo "FAIL  — env expansion broken"; fails=$((fails + 1)); fi

# (15) --list mode is informational, exit 0.
numob_assert "--list mode is informational" 0 --list "$ndir/improve.toml"

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails test(s) FAILED" >&2
  exit 1
fi
echo "all gate tests passed"
