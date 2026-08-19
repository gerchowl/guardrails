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

# Dir-walk mode prefixes every path with `./` (files() sed), so a configured glob
# WITHOUT a leading `*` (vendor/*, scripts/*) must still match — normalize `./` off
# before glob matching, in every gate that takes path globs.
mkdir -p "$tmp/globroot/vendor"
printf 'fn f() { println!("x"); }\n' > "$tmp/globroot/vendor/out.rs"
( cd "$tmp/globroot" && GUARDRAILS_OUTPUT_GLOBS='vendor/*' "$debug_gate" ./vendor/out.rs >/dev/null 2>&1 )
if [ $? = 0 ]; then echo "ok    — output glob matches ./-prefixed explicit path"
else echo "FAIL  — output glob missed ./-prefixed explicit path"; fails=$((fails + 1)); fi
( cd "$tmp/globroot" && GUARDRAILS_OUTPUT_GLOBS='vendor/*' "$debug_gate" . >/dev/null 2>&1 )
if [ $? = 0 ]; then echo "ok    — output glob matches under dir-walk (./ prefix)"
else echo "FAIL  — output glob missed dir-walked ./-prefixed path"; fails=$((fails + 1)); fi

# --- no false positive on innocuous code -------------------------------------
printf 'fn f() -> u32 { 1 + 1 }\n' > "$tmp/src/clean.rs"
assert "clean code passes" 0 -- "$tmp/src/clean.rs"

# --- batching regression guards (one grep per file-type, not per file) --------
# Attribution across a multi-file batch must stay correct, and paths with spaces
# must survive (a naive unquoted batch breaks both). Green before and after the
# fork-storm refactor — they guard it.
mkdir -p "$tmp/nd_multi"
printf 'fn a() -> u32 { 1 }\n'          > "$tmp/nd_multi/a.rs"   # clean
printf 'fn b() { println!("x"); }\n'    > "$tmp/nd_multi/b.rs"   # leak
nd_out="$("$debug_gate" "$tmp/nd_multi" 2>/dev/null)"
if printf '%s' "$nd_out" | grep -q 'b\.rs' && ! printf '%s' "$nd_out" | grep -q 'a\.rs'; then
  echo "ok    — batched scan attributes the hit to the right file"
else echo "FAIL  — batched scan mis-attributes across files"; fails=$((fails + 1)); fi
mkdir -p "$tmp/nd_space"
printf 'fn b() { println!("x"); }\n' > "$tmp/nd_space/weird name.rs"
( "$debug_gate" "$tmp/nd_space" >/dev/null 2>&1 )
if [ $? = 1 ]; then echo "ok    — filename with a space is still scanned"
else echo "FAIL  — filename with a space slips the batched scan"; fails=$((fails + 1)); fi
# The guardrails-ok escape is per-LINE-CONTENT; a path containing the substring
# must not suppress findings under it (the joined file:line:content filter bug).
mkdir -p "$tmp/nd_okpath/guardrails-ok-examples"
printf 'fn b() { println!("x"); }\n' > "$tmp/nd_okpath/guardrails-ok-examples/leak.rs"
( "$debug_gate" "$tmp/nd_okpath" >/dev/null 2>&1 )
if [ $? = 1 ]; then echo "ok    — guardrails-ok in a PATH does not suppress findings"
else echo "FAIL  — guardrails-ok path suppresses real findings"; fails=$((fails + 1)); fi
# …while the line-content escape still works through the batched path.
printf 'fn c() { println!("x"); } // guardrails-ok\n' > "$tmp/nd_okpath/guardrails-ok-examples/ok.rs"
( "$debug_gate" "$tmp/nd_okpath/guardrails-ok-examples/ok.rs" >/dev/null 2>&1 )
if [ $? = 0 ]; then echo "ok    — guardrails-ok line escape survives batching"
else echo "FAIL  — guardrails-ok line escape broken in batched scan"; fails=$((fails + 1)); fi
# Mixed rust+web batch: both pattern families detect through the batched path.
mkdir -p "$tmp/nd_mixed"
printf 'fn b() { println!("x"); }\n'  > "$tmp/nd_mixed/leak.rs"
printf 'console.log("x");\n'          > "$tmp/nd_mixed/leak.ts"
nd_mixed_out="$("$debug_gate" "$tmp/nd_mixed" 2>/dev/null)"
if printf '%s' "$nd_mixed_out" | grep -q 'leak\.rs' && printf '%s' "$nd_mixed_out" | grep -q 'leak\.ts'; then
  echo "ok    — mixed rust+web batch detects both families"
else echo "FAIL  — mixed rust+web batch misses a family"; fails=$((fails + 1)); fi

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

# …and a relative root-src path is still CAUGHT (insurance: no gate may grow an
# inclusion guard that silently exempts single-crate `src/*` — see no-hardcoded).
( cd "$tmp" && "$here/no-debug-leftovers.sh" src/leak_dbgx.rs >/dev/null 2>&1 )
if [ $? = 1 ]; then echo "ok    — no-debug-leftovers catches relative root-src path"
else echo "FAIL  — no-debug-leftovers missed relative root-src path"; fails=$((fails + 1)); fi

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

# --- no-hardcoded: single-crate root src/ layout (relative paths, as pre-commit passes them) ---
# The inclusion guard matched only `*/src/*` (workspace `crates/*/src/**`); a root-src repo's
# `src/foo.rs` never matched, so the gate silently exempted the ENTIRE repo (vacuously green).
hard_layout() { # desc, want-exit, root, path...
  local desc="$1" want="$2" hroot="$3"; shift 3
  ( cd "$hroot" && "$hard_gate" "$@" >/dev/null 2>&1 )
  if [ "$?" = "$want" ]; then echo "ok    — $desc"; else echo "FAIL  — $desc"; fails=$((fails + 1)); fi
}
mkdir -p "$tmp/rootcrate/src" "$tmp/rootcrate/crates/lib/src"
printf 'let n = 100_000;\n' > "$tmp/rootcrate/src/hard_rel.rs"
printf 'let n = 100_000;\n' > "$tmp/rootcrate/build.rs"
printf 'let n = 100_000;\n' > "$tmp/rootcrate/crates/lib/src/w.rs"
hard_layout "root-src relative path is scanned"        1 "$tmp/rootcrate" src/hard_rel.rs
hard_layout "./-prefixed root-src path is scanned"     1 "$tmp/rootcrate" ./src/hard_rel.rs
hard_layout "non-src build.rs stays exempt"            0 "$tmp/rootcrate" build.rs
hard_layout "workspace crates/*/src/* still scanned"   1 "$tmp/rootcrate" crates/lib/src/w.rs
# discovery isolated to a root WITHOUT crates/, so only root src/ can trip it
mkdir -p "$tmp/rootonly/src"
printf 'let n = 100_000;\n' > "$tmp/rootonly/src/hard_rel.rs"
hard_layout "no-args discovery finds root src/ too"    1 "$tmp/rootonly"

# --- no-hardcoded: #[cfg(test)] exempts the FOLLOWING ITEM, not the rest of the file ---
# The awk `intest` flag never reset — any prod code after a mid-file test attr/mod was
# skipped to EOF. Only the attributed item's body (or a brace-less item) is exempt.
hard_assert "prod value above trailing test mod flagged"          1 -- 'let n = 500;
#[cfg(test)]
mod tests { fn t() {} }'
hard_assert "value inside cfg(test) mod stays exempt"             0 -- '#[cfg(test)]
mod tests { const N: u32 = 500; }'
hard_assert "prod value AFTER a cfg(test) fn is flagged"          1 -- '#[cfg(test)]
fn helper() { let ok = 1; }
let n = 500;'
hard_assert "prod value between two cfg(test) mods is flagged"    1 -- '#[cfg(test)]
mod a { const X: u32 = 900; }
let n = 500;
#[cfg(test)]
mod b { const Y: u32 = 900; }'
hard_assert "brace-less cfg(test) item does not eat the file"     1 -- '#[cfg(test)]
use foo::bar;
let n = 500;'
hard_assert "multi-line cfg(test) mod body stays exempt"          0 -- '#[cfg(test)]
mod tests {
    const N: u32 = 500;
    fn t() { let x = 3.7; }
}'

# --- no-hardcoded: const_tunable!/config! exempt the BLOCK, not just the opener ---
# The header has always documented "is inside a const_tunable!(...) invocation", but the
# rule only matched the line carrying the macro NAME. Since the macro is necessarily
# multi-line, the value sits on a different line -- so the gate flagged the very fix it
# tells you to apply, and a magic number could not be wrapped without also annotating it.
hard_assert "value inside a multi-line const_tunable! is exempt"   0 -- 'const_tunable!(
    /// Doc line.
    const MAX_THING: u32 = 100_000,
    "description"
);'
hard_assert "value inside a path-qualified const_tunable! is exempt" 0 -- 'guardrails_tunables::const_tunable!(
    /// Doc line.
    const MAX_THING: u32 = 100_000,
    "description"
);'
hard_assert "multi-line config! is exempt too"                     0 -- 'config!(
    const LIMIT: u32 = 500,
    "description"
);'
# THE CONTROL THAT MATTERS: if the paren depth never returns to zero, everything after
# the first const_tunable! goes unscanned to EOF -- the exact shape of the intest bug
# fixed above. A bare value AFTER the block must still be caught.
hard_assert "prod value AFTER a const_tunable! block is flagged"    1 -- 'const_tunable!(
    const MAX_THING: u32 = 100_000,
    "description"
);
let n = 500;'
hard_assert "value between two const_tunable! blocks is flagged"    1 -- 'const_tunable!(
    const A: u32 = 100_000,
    "a"
);
let n = 500;
const_tunable!(
    const B: u32 = 100_000,
    "b"
);'
# A close-paren inside a doc comment or string must not end the block early, or the
# depth counter closes on the wrong line and the real value leaks through.
hard_assert "close-paren in a doc comment does not end the block"   0 -- 'const_tunable!(
    /// Mentions a paren pair (like this) mid-sentence.
    const MAX_THING: u32 = 100_000,
    "description (with parens) inside"
);'

# --- no-hardcoded: baseline ratchet mode (issue #30) ---------------------------
# A committed per-file count snapshot flips the gate to enforce-on-growth /
# nudge-on-burn-down / silent-at-baseline; --record-baseline only ever tightens.
rroot="$tmp/ratchet"; mkdir -p "$rroot/src"
rbl="$rroot/bl.txt"
rat_run() { # env..., --, args... (gate run from $rroot; returns gate exit)
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  ( cd "$rroot" && env GUARDRAILS_HARDCODED_BASELINE="$rbl" "${envs[@]}" "$hard_gate" "$@" )
}
rat_check() { # desc, want-exit, got-exit
  if [ "$3" = "$2" ]; then echo "ok    — ratchet: $1"
  else echo "FAIL  — ratchet: $1 (want exit $2, got $3)"; fails=$((fails + 1)); fi
}
printf 'let a = 3.7;\nlet b = 5.9;\n' > "$rroot/src/legacy.rs" # 2 hits of debt
rat_run -- src/legacy.rs >/dev/null 2>&1
rat_check "no baseline → all-or-nothing still fails" 1 $?
rat_run -- --record-baseline >/dev/null 2>&1
rat_check "--record-baseline snapshots the debt" 0 $?
if grep -q "src/legacy.rs	2" "$rbl"; then echo "ok    — ratchet: baseline holds the per-file count"
else echo "FAIL  — ratchet: baseline count wrong ($(cat "$rbl" 2>/dev/null))"; fails=$((fails + 1)); fi
rat_run -- src/legacy.rs >/dev/null 2>&1
rat_check "count == baseline passes" 0 $?
rat_out="$(rat_run -- src/legacy.rs 2>&1)"
if [ -z "$rat_out" ]; then echo "ok    — ratchet: at-baseline is SILENT (no legacy noise)"
else echo "FAIL  — ratchet: at-baseline emitted output"; fails=$((fails + 1)); fi
printf 'let c = 9.9;\n' >> "$rroot/src/legacy.rs" # grow: 3 hits
rat_run -- src/legacy.rs >/dev/null 2>&1
rat_check "growth past baseline HARD FAILS" 1 $?
rat_run -- --record-baseline >/dev/null 2>&1
rat_check "--record-baseline refuses a regression" 1 $?
if grep -q "src/legacy.rs	2" "$rbl"; then echo "ok    — ratchet: refused record leaves baseline untouched"
else echo "FAIL  — ratchet: refused record clobbered the baseline"; fails=$((fails + 1)); fi
printf 'let a = 3.7;\n' > "$rroot/src/legacy.rs" # burn down: 1 hit
rat_out="$(rat_run -- src/legacy.rs 2>&1)"; rat_got=$?
rat_check "burn-down below baseline passes" 0 $rat_got
if printf '%s' "$rat_out" | grep -q NUDGE; then echo "ok    — ratchet: burn-down nudges to re-record"
else echo "FAIL  — ratchet: burn-down did not nudge"; fails=$((fails + 1)); fi
rat_run -- --record-baseline >/dev/null 2>&1
rat_check "re-record after burn-down tightens" 0 $?
if grep -q "src/legacy.rs	1" "$rbl"; then echo "ok    — ratchet: baseline ratcheted down (2 → 1)"
else echo "FAIL  — ratchet: baseline did not tighten"; fails=$((fails + 1)); fi
printf 'let n = 100_000;\n' > "$rroot/src/newfile.rs" # new file = 0 budget
rat_run -- src/newfile.rs >/dev/null 2>&1
rat_check "new file with hits fails (absent = baseline 0)" 1 $?
rm "$rroot/src/newfile.rs"
printf 'let clean = 1;\n' > "$rroot/src/clean.rs"
rat_run -- src/clean.rs >/dev/null 2>&1
rat_check "clean staged file passes under a baseline" 0 $?

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
# region body LENGTH changes under --fix while another region follows: the truncation
# point must be tracked in rebuilt-output coordinates, not source line numbers — using
# file line numbers eats everything between the regions once the first fill shifts lines.
printf '%s\n' '<!-- guardrails:derived cmd="seq 3" -->' '<!-- guardrails:derived:end -->' \
  'between-regions prose' \
  '<!-- guardrails:derived cmd="echo z" -->' 'STALE' '<!-- guardrails:derived:end -->' \
  > "$tmp/dd-shift.md"
dd_assert "derived-docs flags empty region needing multi-line fill" 1 "$tmp/dd-shift.md"
dd_assert "derived-docs --fix with body-length shift exits 0"       0 "$tmp/dd-shift.md" --fix
dd_assert "derived-docs passes after shifted multi-region fix"      0 "$tmp/dd-shift.md"
if grep -q 'between-regions prose' "$tmp/dd-shift.md" && grep -q '^z$' "$tmp/dd-shift.md" \
  && grep -q '^2$' "$tmp/dd-shift.md" && [ "$(grep -c 'guardrails:derived' "$tmp/dd-shift.md")" = 4 ]; then
  echo "ok    — derived-docs --fix preserves structure across a body-length shift"
else
  echo "FAIL  — derived-docs --fix corrupted the file after a body-length shift"; fails=$((fails + 1))
fi

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
# Own-line marker ABOVE the flagged line: rustfmt wraps over-long trailing comments onto the NEXT
# line (where they suppress nothing), so the stable convention is a pure-comment line above.
trace_assert "own-line guardrails-ok above suppresses next line" 0 -- 'fn f() {
    // guardrails-ok(no-raw-trace-fields): pending migration
    info!(user = ?user);
}'
trace_assert "guardrails-ok in a string above does NOT suppress" 1 -- 'fn f() {
    let x = "guardrails-ok";
    info!(user = ?user);
}'
trace_assert "marker above wrong line does not leak further down" 1 -- 'fn f() {
    // guardrails-ok(no-raw-trace-fields): pending migration
    let y = 1;
    info!(user = ?user);
}'
trace_assert "allowlisted schema surface is skipped"     0 \
  "GUARDRAILS_TRACE_ALLOW_GLOBS=*/src/trace.rs" -- 'fn f() { info!(user = ?user); }'
# allow-glob without a leading `*` must survive the dir-walk `./` prefix too
mkdir -p "$tmp/globroot/schema"
printf 'fn f() { info!(user = ?user); }\n' > "$tmp/globroot/schema/fields.rs"
( cd "$tmp/globroot" && GUARDRAILS_TRACE_ALLOW_GLOBS='schema/*' "$trace_gate" ./schema/fields.rs >/dev/null 2>&1 )
if [ $? = 0 ]; then echo "ok    — trace allow-glob matches ./-prefixed path"
else echo "FAIL  — trace allow-glob missed ./-prefixed path"; fails=$((fails + 1)); fi
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

# --- duplication: token-window clone nudge -----------------------------------
# Reinvention-vs-reuse detector. Multi-file by nature, so it runs on a DIR root
# (not a single file). Default = NUDGE (report, exit 0); GUARDRAILS_DUP_ENFORCE=1
# promotes to a hard gate. Precision-first: an exact ≥K normalized-line match is
# a real clone, so false positives stay near zero (a noisy nudge trains bypass).
dup_gate="$here/duplication.sh"
# dup_assert <desc> <want-exit> <env...> -- <dir>
dup_assert() {
  local desc="$1" want="$2"; shift 2
  local env=()
  while [ "$1" != "--" ]; do env+=("$1"); shift; done
  shift
  env "${env[@]}" "$dup_gate" "$1" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$want" ]; then echo "ok    — $desc"
  else echo "FAIL  — $desc (want exit $want, got $got)"; fails=$((fails + 1)); fi
}

# A ≥6 significant-line block (the class of hand-rolled modal/confirm handler
# that drifts into N near-identical copies).
dup_block() { cat <<'RS'
fn handle_close(state: &mut State) {
    state.dialog = None;
    state.mode = if state.active.is_some() {
        Mode::Terminal
    } else {
        Mode::Navigate
    };
    state.dirty = true;
}
RS
}

# CAUGHT: same block in two files, differing only in indentation + comments
# (normalization must see through whitespace/comment noise).
mkdir -p "$tmp/dup_clone"
dup_block > "$tmp/dup_clone/a.rs"
{ echo "// an unrelated leading comment"; dup_block | sed 's/^/    /'; echo "    // trailing note"; } > "$tmp/dup_clone/b.rs"
dup_assert "clone across two files is a NUDGE (exit 0)"          0 -- "$tmp/dup_clone"
dup_assert "clone promoted to hard gate under ENFORCE"          1 "GUARDRAILS_DUP_ENFORCE=1" -- "$tmp/dup_clone"

# NO FALSE POSITIVE: two genuinely distinct files.
mkdir -p "$tmp/dup_unique"
printf 'fn alpha() {\n    let x = compute_alpha();\n    x + 1\n}\n' > "$tmp/dup_unique/a.rs"
printf 'fn beta() {\n    let y = compute_beta();\n    y * 2\n}\n'    > "$tmp/dup_unique/b.rs"
dup_assert "distinct files produce no clone"                    0 "GUARDRAILS_DUP_ENFORCE=1" -- "$tmp/dup_unique"

# THRESHOLD: an identical block of only 5 significant lines (< K=6) is ignored.
mkdir -p "$tmp/dup_short"
short_block() { cat <<'RS'
fn s() {
    let a = one();
    let b = two();
    let c = three();
    let d = four();
}
RS
}
short_block > "$tmp/dup_short/a.rs"; short_block > "$tmp/dup_short/b.rs"
dup_assert "shared block below the ≥6-line threshold is ignored" 0 "GUARDRAILS_DUP_ENFORCE=1" -- "$tmp/dup_short"

# ESCAPE: guardrails-ok on one twin removes it from the corpus → no pair.
mkdir -p "$tmp/dup_ok"
dup_block > "$tmp/dup_ok/a.rs"
{ echo "// guardrails-ok"; dup_block; } > "$tmp/dup_ok/b.rs"
dup_assert "guardrails-ok on one twin suppresses the pair"      0 "GUARDRAILS_DUP_ENFORCE=1" -- "$tmp/dup_ok"

# ESCAPE: GUARDRAILS_DUP_ALLOW glob excludes a twin the same way.
dup_assert "GUARDRAILS_DUP_ALLOW glob excludes a twin"         0 "GUARDRAILS_DUP_ENFORCE=1" "GUARDRAILS_DUP_ALLOW=*/b.rs" -- "$tmp/dup_clone"

# TUNABLE: dropping the threshold to 5 makes the short block fire.
dup_assert "GUARDRAILS_DUP_MIN_LINES=5 catches the 5-line block" 1 "GUARDRAILS_DUP_ENFORCE=1" "GUARDRAILS_DUP_MIN_LINES=5" -- "$tmp/dup_short"

# DETERMINISM: guardrails bans wall-clock/random for reproducibility — identical
# input must yield byte-identical output across runs.
r1="$(GUARDRAILS_DUP_ENFORCE=1 "$dup_gate" "$tmp/dup_clone" 2>&1)"
r2="$(GUARDRAILS_DUP_ENFORCE=1 "$dup_gate" "$tmp/dup_clone" 2>&1)"
if [ "$r1" = "$r2" ]; then echo "ok    — duplication report is deterministic"
else echo "FAIL  — duplication report differs across runs"; fails=$((fails + 1)); fi

# --- duplication: staleness escalation (ledger + git-age → auto-promote) ------
# The nudge earns the right to become a gate: a clone that PERSISTS undealt-with
# across commits has a decaying false-positive probability, so age promotes it
# nudge → hard block. Ledger is committed state (like perf-history.csv); age is
# counted in COMMITS (git as the deterministic clock — no wall-time).
led="$tmp/dup_ledger.tsv"
aged="$tmp/dup_aged"
mkdir -p "$aged"
dup_block > "$aged/a.rs"
dup_block > "$aged/b.rs"
git -C "$aged" init -q
git -C "$aged" config user.email t@t; git -C "$aged" config user.name t
git -C "$aged" add -A && git -C "$aged" commit -q -m c1
# --record stamps the clone group's first-seen at HEAD (c1) into the ledger.
( cd "$aged" && GUARDRAILS_DUP_LEDGER="$led" "$dup_gate" --record "$aged" >/dev/null 2>&1 )
if [ -s "$led" ]; then echo "ok    — --record writes the clone ledger"
else echo "FAIL  — --record did not write a ledger"; fails=$((fails + 1)); fi
# One more commit → the clone has persisted 1 commit since first-seen.
: > "$aged/other.txt"; git -C "$aged" add -A && git -C "$aged" commit -q -m c2
# age(1) ≥ ENFORCE_AGE(1) → persisted clone auto-promotes to a hard block…
( cd "$aged" && GUARDRAILS_DUP_LEDGER="$led" GUARDRAILS_DUP_ENFORCE_AGE=1 "$dup_gate" "$aged" >/dev/null 2>&1 )
if [ $? = 1 ]; then echo "ok    — persisted clone auto-promotes to ENFORCE by age"
else echo "FAIL  — persisted clone did not auto-promote"; fails=$((fails + 1)); fi
# …but a threshold it has not reached keeps it a nudge (exit 0).
( cd "$aged" && GUARDRAILS_DUP_LEDGER="$led" GUARDRAILS_DUP_ENFORCE_AGE=99 "$dup_gate" "$aged" >/dev/null 2>&1 )
if [ $? = 0 ]; then echo "ok    — clone below the age threshold stays a nudge"
else echo "FAIL  — clone below age threshold wrongly blocked"; fails=$((fails + 1)); fi
# Resolving it (decorate one twin) drops it from the ledger on the next --record.
{ echo "// guardrails-ok"; dup_block; } > "$aged/b.rs"
git -C "$aged" add -A && git -C "$aged" commit -q -m c3
( cd "$aged" && GUARDRAILS_DUP_LEDGER="$led" "$dup_gate" --record "$aged" >/dev/null 2>&1 )
if [ ! -s "$led" ]; then echo "ok    — resolved clone drops from the ledger (ratchet-shrink)"
else echo "FAIL  — resolved clone lingers in the ledger"; fails=$((fails + 1)); fi

# --- protect-trunk: refuse direct commits on a protected branch ----------------
# Workflow gate, not a content gate: HEAD's branch (or the branch a rebase is
# rewriting) must not be in the protected set. CI / GITHUB_ACTIONS are cleared in
# every row so the suite behaves identically locally and in CI (which sets them).
pt_gate="$here/protect-trunk.sh"
ptr="$tmp/pt-repo"
git init -q -b main "$ptr" && git -C "$ptr" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
pt_assert() { # desc, want-exit, env-assignments..., -- (runs gate inside $ptr)
  local desc="$1" want="$2"; shift 2
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  ( cd "$ptr" && env -u CI -u GITHUB_ACTIONS -u GUARDRAILS_ALLOW_TRUNK -u GUARDRAILS_PROTECTED_BRANCHES "${envs[@]}" "$pt_gate" >/dev/null 2>&1 )
  local got=$?
  if [ "$got" = "$want" ]; then echo "ok    — protect-trunk: $desc"
  else echo "FAIL  — protect-trunk: $desc (want exit $want, got $got)"; fails=$((fails + 1)); fi
}
pt_assert "blocks a commit on main (default set)"       1 --
git -C "$ptr" branch -m master
pt_assert "blocks a commit on master (default set)"     1 --
git -C "$ptr" switch -q -c feat/x
pt_assert "feature branch passes"                        0 --
git -C "$ptr" checkout -q --detach
pt_assert "detached HEAD is allowed"                     0 --
# Rebase-of-protected probe: fake the rebase state files (a real `git rebase` of a
# single-commit branch finishes atomically; the state file is what the gate reads).
git_dir_pt="$(git -C "$ptr" rev-parse --git-dir)"; [ "${git_dir_pt#/}" = "$git_dir_pt" ] && git_dir_pt="$ptr/$git_dir_pt"
mkdir -p "$git_dir_pt/rebase-merge" && echo "refs/heads/master" > "$git_dir_pt/rebase-merge/head-name"
pt_assert "rebase OF a protected branch still blocks"    1 --
rm -rf "$git_dir_pt/rebase-merge"
git -C "$ptr" switch -q master
pt_assert "GUARDRAILS_ALLOW_TRUNK=1 escape passes"       0 GUARDRAILS_ALLOW_TRUNK=1 --
pt_assert "CI context auto-allows"                       0 CI=true --
pt_assert "GITHUB_ACTIONS context auto-allows"           0 GITHUB_ACTIONS=true --
pt_assert "knob REPLACES default (master not protected)" 0 GUARDRAILS_PROTECTED_BRANCHES='release/*' --
pt_assert "empty knob disables protection"               0 GUARDRAILS_PROTECTED_BRANCHES= --
# pt_on: switch AND verify — an invalid branch name must fail the row loudly, not
# leave HEAD on the previous branch silently mis-testing (a review caught two such rows).
pt_on() {
  git -C "$ptr" switch -q -c "$1" 2>/dev/null
  [ "$(git -C "$ptr" symbolic-ref --short HEAD)" = "$1" ] && return 0
  echo "FAIL  — protect-trunk: could not create test branch '$1'"; fails=$((fails + 1)); return 1
}
pt_on release/1.2/hotfix && {
pt_assert "glob knob matches nested release branch"      1 GUARDRAILS_PROTECTED_BRANCHES='release/*' --
pt_assert "boundary empties in ':main:' don't match-all" 0 GUARDRAILS_PROTECTED_BRANCHES=':main:' --
}
# git refuses space/'['/'*' in ref names, so hostile-branch rows are unrepresentable;
# glob semantics are exercised from the PATTERN side instead (? must match exactly one char).
pt_on weirdo && {
pt_assert "glob ? pattern matches one extra char"        1 GUARDRAILS_PROTECTED_BRANCHES='weird?' --
pt_assert "glob ? pattern needs its char (no match)"     0 GUARDRAILS_PROTECTED_BRANCHES='weirdo?' --
}
mkdir -p "$tmp/pt-notrepo"
( cd "$tmp/pt-notrepo" && env -u CI -u GITHUB_ACTIONS "$pt_gate" >/dev/null 2>&1 )
if [ $? = 0 ]; then echo "ok    — protect-trunk: outside a git repo is allowed"
else echo "FAIL  — protect-trunk: blocked outside a git repo"; fails=$((fails + 1)); fi

# --- protect-trunk-push: refuse pushes advancing a protected REMOTE ref --------
# Keyed on the remote ref from pre-push stdin (catches `push origin HEAD:main`
# from a feature branch and cherry-picked/plumbing commits pre-commit never saw).
ptp_gate="$here/protect-trunk-push.sh"
sha_a=1111111111111111111111111111111111111111
sha_z=0000000000000000000000000000000000000000
ptp_assert() { # desc, want-exit, env-assignments..., --, stdin-lines...
  local desc="$1" want="$2"; shift 2
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  printf '%s\n' "$@" | env -u CI -u GITHUB_ACTIONS -u GUARDRAILS_ALLOW_TRUNK -u GUARDRAILS_PROTECTED_BRANCHES -u PRE_COMMIT_REMOTE_BRANCH -u GUARDRAILS_TRUNK_MERGE_GATE -u GUARDRAILS_TRUNK_MERGE_CMD "${envs[@]}" "$ptp_gate" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$want" ]; then echo "ok    — protect-trunk-push: $desc"
  else echo "FAIL  — protect-trunk-push: $desc (want exit $want, got $got)"; fails=$((fails + 1)); fi
}
ptp_assert "push to protected remote ref blocks"      1 -- "refs/heads/feat/x $sha_a refs/heads/main $sha_a"
ptp_assert "HEAD:main refspec from feature blocks"    1 -- "HEAD $sha_a refs/heads/main $sha_a"
ptp_assert "feature-to-feature push passes"           0 -- "refs/heads/feat/x $sha_a refs/heads/feat/x $sha_a"
ptp_assert "deleting a remote branch is not blocked"  0 -- "(delete) $sha_z refs/heads/main $sha_a"
ptp_assert "tag push to a 'main' tag is not a head"   0 -- "refs/tags/main $sha_a refs/tags/main $sha_a"
ptp_assert "mixed batch: one protected ref blocks"    1 -- "refs/heads/feat/x $sha_a refs/heads/feat/x $sha_a" "refs/heads/feat/x $sha_a refs/heads/master $sha_a"
ptp_assert "ALLOW_TRUNK escape passes"                0 GUARDRAILS_ALLOW_TRUNK=1 -- "refs/heads/feat/x $sha_a refs/heads/main $sha_a"
ptp_assert "CI context auto-allows"                   0 CI=true -- "refs/heads/feat/x $sha_a refs/heads/main $sha_a"
ptp_assert "knob glob protects release/* remote ref"  1 GUARDRAILS_PROTECTED_BRANCHES='release/*' -- "refs/heads/feat/x $sha_a refs/heads/release/1.2 $sha_a"
ptp_assert "empty knob disables push protection"      0 GUARDRAILS_PROTECTED_BRANCHES= -- "refs/heads/feat/x $sha_a refs/heads/main $sha_a"
ptp_assert "empty stdin (nothing to push) passes"     0 -- ""
# prek/pre-commit run system hooks with stdin nulled and export the parsed remote ref
# instead (PRE_COMMIT_REMOTE_BRANCH, full refs/heads/... form) — the env fallback path.
ptp_assert "env fallback blocks protected ref (prek)" 1 PRE_COMMIT_REMOTE_BRANCH=refs/heads/main -- ""
ptp_assert "env fallback passes feature ref (prek)"   0 PRE_COMMIT_REMOTE_BRANCH=refs/heads/feat/x -- ""
ptp_assert "stdin takes precedence over env fallback" 0 PRE_COMMIT_REMOTE_BRANCH=refs/heads/main -- "refs/heads/feat/x $sha_a refs/heads/feat/x $sha_a"
ptp_assert "env fallback honors empty-knob opt-out"   0 GUARDRAILS_PROTECTED_BRANCHES= PRE_COMMIT_REMOTE_BRANCH=refs/heads/main -- ""
# Trunk-merge-gate (issue #18): GUARDRAILS_TRUNK_MERGE_GATE=1 turns the refusal into
# "pass iff the check suite is green right now" — pre-push earns the trunk advance.
ptp_assert "trunk-merge-gate: green guards EARN the push"  0 GUARDRAILS_TRUNK_MERGE_GATE=1 GUARDRAILS_TRUNK_MERGE_CMD=true -- "refs/heads/feat/x $sha_a refs/heads/main $sha_a"
ptp_assert "trunk-merge-gate: red guards still refuse"     1 GUARDRAILS_TRUNK_MERGE_GATE=1 GUARDRAILS_TRUNK_MERGE_CMD=false -- "refs/heads/feat/x $sha_a refs/heads/main $sha_a"
ptp_assert "trunk-merge-gate off by default (refusal)"     1 -- "refs/heads/feat/x $sha_a refs/heads/main $sha_a"
# The check suite runs at most ONCE per push, however many protected refs match.
tmg_cnt="$tmp/tmg-count"
: > "$tmg_cnt"
printf '#!/bin/sh\necho x >> "%s"\n' "$tmg_cnt" > "$tmp/tmg-cmd" && chmod +x "$tmp/tmg-cmd"
printf '%s\n' "refs/heads/feat/x $sha_a refs/heads/main $sha_a" "refs/heads/feat/x $sha_a refs/heads/master $sha_a" \
  | env -u CI -u GITHUB_ACTIONS GUARDRAILS_TRUNK_MERGE_GATE=1 GUARDRAILS_TRUNK_MERGE_CMD="$tmp/tmg-cmd" "$ptp_gate" >/dev/null 2>&1
if [ "$(grep -c x "$tmg_cnt")" = 1 ]; then echo "ok    — protect-trunk-push: merge-gate cmd memoized (1 run for 2 refs)"
else echo "FAIL  — protect-trunk-push: merge-gate cmd ran $(grep -c x "$tmg_cnt") times"; fails=$((fails + 1)); fi

# --- nudge-ledger: the shared persistence-escalation harness (issue #32) -------
# Gate-agnostic lifecycle: new → quiet · persisted → age-in-commits (+growth) →
# promoted past --enforce-age · resolved → dropped on record. Pins exactly the
# transitions the #31 review flagged: oscillation and orphaned first-seen SHAs.
nl="$here/../tools/nudge-ledger.sh"
nrepo="$tmp/nl-repo"; mkdir -p "$nrepo"
git init -q -b main "$nrepo"
git -C "$nrepo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m c1
nled="$nrepo/led.tsv"
nl_run() { ( cd "$nrepo" && "$nl" "$@" ); }
TABC="$(printf '\t')"
nl_check() { # desc, want-substr, got
  if printf '%s' "$3" | grep -q "$2"; then echo "ok    — nudge-ledger: $1"
  else echo "FAIL  — nudge-ledger: $1 (got: $3)"; fails=$((fails + 1)); fi
}
fnd() { printf 'k1\t%s\tlabel-one\n' "$1"; }
out="$(fnd 2 | nl_run check --ledger "$nled")"
nl_check "unseen finding tiers as new" "k1${TABC}new" "$out"
fnd 2 | nl_run record --ledger "$nled"
if grep -q "k1" "$nled"; then echo "ok    — nudge-ledger: record stamps first-seen"
else echo "FAIL  — nudge-ledger: record wrote nothing"; fails=$((fails + 1)); fi
git -C "$nrepo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m c2
out="$(fnd 2 | nl_run check --ledger "$nled")"
nl_check "persisted finding ages in commits" "k1${TABC}persisted:1" "$out"
out="$(fnd 3 | nl_run check --ledger "$nled")"
nl_check "growth is tiered with prev>now" "persisted:1:grew:2>3" "$out"
out="$(fnd 3 | nl_run check --ledger "$nled" --enforce-age 1)"
nl_check "age past --enforce-age promotes (grew kept)" "promoted:1:grew:2>3" "$out"
# resolved → dropped on record (ratchet-shrink)…
: | nl_run record --ledger "$nled"
if [ ! -s "$nled" ]; then echo "ok    — nudge-ledger: resolved finding drops on record"
else echo "FAIL  — nudge-ledger: resolved finding lingered"; fails=$((fails + 1)); fi
# …and OSCILLATION: reappearing after resolve+record restarts the age at 0 (fresh stamp).
fnd 2 | nl_run record --ledger "$nled"
out="$(fnd 2 | nl_run check --ledger "$nled" --enforce-age 1)"
nl_check "reappeared finding restarts age (no stale promote)" "k1${TABC}persisted:0" "$out"
# Orphaned first-seen (shallow clone / rewritten history): age falls back to 0 + one warning.
printf 'k1\t%s\t2\n' "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" > "$nled"
err="$(fnd 2 | nl_run check --ledger "$nled" --enforce-age 1 2>&1 >/dev/null)"
out="$(fnd 2 | nl_run check --ledger "$nled" --enforce-age 1 2>/dev/null)"
nl_check "orphaned first-seen fails open (age 0, no promote)" "k1${TABC}persisted:0" "$out"
nl_check "orphaned first-seen warns on stderr (not silent)" "unreachable" "$err"
# Garbage --enforce-age is a usage error (exit 2), not a silent misread.
( : | nl_run check --ledger "$nled" --enforce-age abc >/dev/null 2>&1 )
if [ $? = 2 ]; then echo "ok    — nudge-ledger: garbage enforce-age is a loud usage error"
else echo "FAIL  — nudge-ledger: garbage enforce-age accepted"; fails=$((fails + 1)); fi

# --- guardrails-trace: duration+verdict JSONL wrapper (issue #14) --------------
# Transparent wrapper: exit code + streams pass through; one atomic row per run in
# the XDG cache; guardrails last replays the latest run and cannot be swallowed.
trace="$here/../tools/trace.sh"
report="$here/../tools/trace-report.sh"
tdir="$tmp/trace-repo"; mkdir -p "$tdir"
tr_env() { ( cd "$tdir" && env XDG_CACHE_HOME="$tmp/xdg" "$@" ); }
tr_check() { # desc, want, got
  if [ "$3" = "$2" ]; then echo "ok    — trace: $1"
  else echo "FAIL  — trace: $1 (want $2, got $3)"; fails=$((fails + 1)); fi
}
tr_out="$(tr_env env GR_RUN_ID=run1 GR_TRIGGER=pre-commit "$trace" echo-gate -- echo hello)"
tr_check "wrapped command's stdout passes through" hello "$tr_out"
tr_env env GR_RUN_ID=run1 GR_TRIGGER=pre-commit "$trace" fail-gate -- sh -c 'exit 3' >/dev/null 2>&1
tr_check "wrapped exit code is preserved" 3 $?
tfile="$(ls "$tmp"/xdg/guardrails/runs/*.jsonl 2>/dev/null | head -1)"
if [ -n "$tfile" ] && [ "$(grep -c . "$tfile")" = 2 ]; then echo "ok    — trace: one row per run appended"
else echo "FAIL  — trace: expected 2 rows in $tfile"; fails=$((fails + 1)); fi
if grep -q '"gate":"echo-gate","trigger":"pre-commit","verdict":"pass","exit_code":0' "$tfile" \
   && grep -q '"gate":"fail-gate","trigger":"pre-commit","verdict":"fail","exit_code":3' "$tfile"; then
  echo "ok    — trace: rows carry verdict enum + raw exit code"
else echo "FAIL  — trace: row fields wrong: $(cat "$tfile")"; fails=$((fails + 1)); fi
if awk '!/"duration_ms":[0-9]+/ { bad = 1 } END { exit bad }' "$tfile"; then
  echo "ok    — trace: duration_ms is a non-negative integer"
else echo "FAIL  — trace: bad duration_ms"; fails=$((fails + 1)); fi
# guardrails last: latest run only, FAIL duplicated to stderr, exit 1.
tr_env env GR_RUN_ID=run2 GR_TRIGGER=pre-push "$trace" ok-gate -- true >/dev/null 2>&1
last_err="$(tr_env "$report" last 2>&1 >/dev/null)"; last_ec=$?
tr_check "last exits 0 when the latest run is green" 0 $last_ec
tr_env env GR_RUN_ID=run3 GR_TRIGGER=pre-commit "$trace" bad-gate -- false >/dev/null 2>&1
last_out="$(tr_env "$report" last 2>/dev/null)"; last_ec=$?
last_err="$(tr_env "$report" last 2>&1 >/dev/null)"
tr_check "last exits 1 when the latest run has a FAIL" 1 $last_ec
if printf '%s' "$last_err" | grep -q FAIL; then echo "ok    — trace: FAIL is duplicated on stderr (unswallowable)"
else echo "FAIL  — trace: FAIL not on stderr"; fails=$((fails + 1)); fi
if printf '%s' "$last_out" | grep -q run3 && ! printf '%s' "$last_out" | grep -q ok-gate; then
  echo "ok    — trace: last shows only the latest run"
else echo "FAIL  — trace: last mixed runs: $last_out"; fails=$((fails + 1)); fi
# perf report aggregates without error and names the gates.
perf_out="$(tr_env "$report" perf 2>&1)"
if printf '%s' "$perf_out" | grep -q 'echo-gate' && printf '%s' "$perf_out" | grep -q 'p95'; then
  echo "ok    — trace: perf report aggregates per gate"
else echo "FAIL  — trace: perf report broken: $perf_out"; fails=$((fails + 1)); fi
# outside any tracing (no GR_* env): still writes a row with trigger=manual.
tr_env "$trace" manual-gate -- true >/dev/null 2>&1
if grep -q '"gate":"manual-gate","trigger":"manual"' "$tfile"; then
  echo "ok    — trace: bare invocation defaults to trigger=manual"
else echo "FAIL  — trace: manual trigger default missing"; fails=$((fails + 1)); fi

# --- guardrails-stale: calendar+churn staleness vs config thresholds (issue #13) ---
stale="$here/../tools/stale.sh"
srepo="$tmp/stale-repo"; mkdir -p "$srepo"
git init -q -b main "$srepo" && git -C "$srepo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m c1
stop="$(git -C "$srepo" rev-parse --show-toplevel)" # macOS: /var vs /private/var — use git's answer
sslug="$(basename "$stop")-$(printf '%s' "$stop" | git hash-object --stdin | cut -c1-6)"
sdir="$tmp/xdg-stale/guardrails/runs"; mkdir -p "$sdir"
st_run() { ( cd "$srepo" && env XDG_CACHE_HOME="$tmp/xdg-stale" "$stale" "$@" ); }
# no trace + no config → silent, exit 0
rm -f "$sdir/$sslug.jsonl" "$srepo/guardrails-stale.toml"
s_out="$(st_run 2>&1)"; s_ec=$?
if [ "$s_ec" = 0 ] && [ -z "$s_out" ]; then echo "ok    — stale: silent without trace/config"
else echo "FAIL  — stale: noisy without opt-in ($s_ec: $s_out)"; fails=$((fails + 1)); fi
# trace with an OLD green run + max_days=0 → stderr names the gate; exit stays 0
printf '{"v":1,"ts":"2020-01-01T00:00:00Z","run_id":"r1","repo":"x","gate":"cargo-deny","trigger":"pre-push","verdict":"pass","exit_code":0,"duration_ms":5,"changed_files":0}\n' > "$sdir/$sslug.jsonl"
printf '[cargo-deny]\nmax_days = 7\n' > "$srepo/guardrails-stale.toml"
s_err="$(st_run 2>&1 >/dev/null)"; s_ec=$?
if [ "$s_ec" = 0 ] && printf '%s' "$s_err" | grep -q 'cargo-deny.*d'; then echo "ok    — stale: calendar-overdue gate nudged (exit 0)"
else echo "FAIL  — stale: calendar lever broken ($s_ec: $s_err)"; fails=$((fails + 1)); fi
# fresh green run → quiet
printf '{"v":1,"ts":"%s","run_id":"r2","repo":"x","gate":"cargo-deny","trigger":"pre-push","verdict":"pass","exit_code":0,"duration_ms":5,"changed_files":0}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$sdir/$sslug.jsonl"
s_err="$(st_run 2>&1 >/dev/null)"
if [ -z "$s_err" ]; then echo "ok    — stale: freshly-green gate stays quiet"
else echo "FAIL  — stale: false nudge on fresh gate ($s_err)"; fails=$((fails + 1)); fi
# configured gate that never ran green → 'never green'
printf '[clippy]\nmax_days = 7\n' >> "$srepo/guardrails-stale.toml"
s_err="$(st_run 2>&1 >/dev/null)"
if printf '%s' "$s_err" | grep -q 'clippy never green'; then echo "ok    — stale: never-green configured gate surfaces"
else echo "FAIL  — stale: never-green gate invisible ($s_err)"; fails=$((fails + 1)); fi
# --json works without config and carries per-gate stats
rm "$srepo/guardrails-stale.toml"
s_json="$(st_run --json 2>/dev/null)"
if printf '%s' "$s_json" | grep -q '"cargo-deny"' && printf '%s' "$s_json" | grep -q 'days_since_green'; then
  echo "ok    — stale: --json emits per-gate stats without config"
else echo "FAIL  — stale: --json broken ($s_json)"; fails=$((fails + 1)); fi

# --- hot-info: info!/warn! on a per-iteration path (level vs FREQUENCY) ------------
# Heuristic + lexical by design, so the fixtures pin BOTH directions: the naive hot cases it must
# catch, and the depth-decrement cases a sloppy brace tracker would leak into (a macro AFTER a
# closed loop is the load-bearing negative — without it a bad `depth--` marks the rest of the fn hot).
hot_gate="$here/hot-info.sh"
mkdir -p "$tmp/hot"
hot_assert() { # desc, want-exit, env(or --), file-content
  local desc="$1" want="$2"; shift 2
  local env=()
  while [ "$1" != "--" ]; do env+=("$1"); shift; done
  shift
  printf '%s\n' "$1" > "$tmp/hot/h.rs"
  env "${env[@]}" "$hot_gate" "$tmp/hot/h.rs" >/dev/null 2>&1
  if [ "$?" = "$want" ]; then echo "ok    — $desc"; else echo "FAIL  — $desc"; fails=$((fails + 1)); fi
}
# NOTE: default mode is a NUDGE (exit 0 even on hits), so catch-cases assert under ENFORCE=1.
E=GUARDRAILS_HOTINFO_ENFORCE=1

hot_assert "plain info! in a fn body is NOT hot"       0 $E -- 'fn f() { info!("started"); }'
hot_assert "info! inside loop {} is flagged"           1 $E -- 'fn f() {
    loop {
        info!("tick");
    }
}'
hot_assert "info! inside for is flagged"               1 $E -- 'fn f() {
    for x in xs {
        info!("item");
    }
}'
hot_assert "warn! inside while is flagged"             1 $E -- 'fn f() {
    while cond {
        warn!("retry");
    }
}'
hot_assert "single-line for { info! } is flagged"      1 $E -- 'fn f() { for x in xs { info!("hot"); } }'
for hotfn in tick poll_once sample_gpu heartbeat render_frame update_state; do
  hot_assert "info! in fn $hotfn() is flagged"         1 $E -- "fn $hotfn() {
    info!(\"beat\");
}"
done
# LOAD-BEARING negatives — a leaked brace depth would flag these.
hot_assert "info! AFTER a closed loop is NOT flagged"  0 $E -- 'fn f() {
    for _ in xs { }
    info!("finished");
}'
# SAME-LINE variant of the above. The multi-line fixture alone passed while the one-liner
# false-positived: the prefix brace-balance was counting the enclosing fn's `{` too, so the
# balance never returned to zero. Caught in review; this pins it.
hot_assert "info! after a closed loop ON ONE LINE is NOT flagged" 0 $E -- 'fn f() { for _ in xs { } info!("done"); }'
hot_assert "info! BETWEEN two loops is NOT flagged"    0 $E -- 'fn f() {
    for _ in xs { }
    info!("midpoint");
    for _ in ys { }
}'
hot_assert "info! after a hot fn closes is NOT flagged" 0 $E -- 'fn tick() {
    let x = 1;
}
fn lifecycle() {
    info!("started");
}'
hot_assert "loop keyword inside a string is NOT a loop" 0 $E -- 'fn f() { let s = "loop { info!(x) }"; }'
# Nested constructs that ARE hot.
hot_assert "warn! in a closure inside for is flagged"  1 $E -- 'fn f() {
    for x in xs {
        xs.map(|v| { warn!("v"); });
    }
}'
hot_assert "info! in a match arm inside loop flagged"  1 $E -- 'fn f() {
    loop {
        match e {
            _ => { info!("arm"); }
        }
    }
}'
# Escape hatches — the annotation is the deliverable (forced deliberation, diff-visible).
hot_assert "guardrails-ok on the line suppresses"      0 $E -- 'fn f() {
    loop {
        info!("tick"); // guardrails-ok(hot-info): bounded, 3 iterations
    }
}'
hot_assert "own-line guardrails-ok above suppresses"   0 $E -- 'fn f() {
    loop {
        // guardrails-ok(hot-info): startup only
        info!("tick");
    }
}'
hot_assert "marker above the WRONG line does not leak" 1 $E -- 'fn f() {
    loop {
        // guardrails-ok(hot-info): startup only
        let y = 1;
        info!("tick");
    }
}'
# The known false positive: a startup loop that runs 3x is CORRECT code and WILL be flagged.
# Documented, not pretended away — the annotation is the answer.
hot_assert "known FP (startup loop) is flagged"        1 $E -- 'fn init() {
    for c in configs {
        info!("loaded config");
    }
}'
hot_assert "known FP suppressed by an annotated reason" 0 $E -- 'fn init() {
    for c in configs {
        info!("loaded config"); // guardrails-ok(hot-info): startup, len(configs) == 3
    }
}'
# NUDGE contract: hits do NOT fail by default; the ENFORCE knob promotes.
hot_assert "hits are a NUDGE by default (exit 0)"      0 -- 'fn f() {
    loop {
        info!("tick");
    }
}'
# Allow-glob, with and without a leading `*` (the ./-prefix normalization every gate must satisfy).
mkdir -p "$tmp/hotroot/vendored"
printf 'fn f() {\n    loop {\n        info!("tick");\n    }\n}\n' > "$tmp/hotroot/vendored/gen.rs"
( cd "$tmp/hotroot" && GUARDRAILS_HOTINFO_ENFORCE=1 GUARDRAILS_HOTINFO_ALLOW='vendored/*' "$hot_gate" ./vendored/gen.rs >/dev/null 2>&1 )
if [ $? = 0 ]; then echo "ok    — hot-info allow-glob matches ./-prefixed path"
else echo "FAIL  — hot-info allow-glob missed ./-prefixed path"; fails=$((fails + 1)); fi
mkdir -p "$tmp/hotroot/src/vendored"
cp "$tmp/hotroot/vendored/gen.rs" "$tmp/hotroot/src/vendored/gen.rs"
( cd "$tmp/hotroot" && GUARDRAILS_HOTINFO_ENFORCE=1 GUARDRAILS_HOTINFO_ALLOW='*/vendored/*' "$hot_gate" ./src/vendored/gen.rs >/dev/null 2>&1 )
if [ $? = 0 ]; then echo "ok    — hot-info allow-glob matches nested path with leading *"
else echo "FAIL  — hot-info allow-glob broken with leading *"; fails=$((fails + 1)); fi
# tests/ exempt even for a real hot info! (relative path, as pre-commit passes it)
printf 'fn f() {\n    loop {\n        info!("tick");\n    }\n}\n' > "$tmp/tests/hot_leak.rs"
( cd "$tmp" && GUARDRAILS_HOTINFO_ENFORCE=1 "$hot_gate" tests/hot_leak.rs >/dev/null 2>&1 )
if [ $? = 0 ]; then echo "ok    — hot-info excludes top-level tests/ (relative)"
else echo "FAIL  — hot-info flags top-level tests/ (relative)"; fails=$((fails + 1)); fi
# --- adversarial round: lexer edge cases that a line-oriented scanner gets wrong ---------------
# Every case below produced a WRONG verdict before the scanner became a positional lexer that
# carries string/comment state across lines and evaluates a macro at its own offset.
hot_assert "escaped quotes do not leak a fake loop"    0 $E -- 'fn f() { let s = "he said \"loop {\""; info!("plain"); }'
hot_assert "raw string containing loop{ is not a loop" 0 $E -- 'fn f() {
    let s = r#"
    loop {
    "#;
    info!("not in loop");
}'
hot_assert "raw string containing } cannot close a real loop" 1 $E -- 'fn f() {
    for x in xs {
        let s = r#"
        }
        "#;
        info!("really hot");
    }
}'
hot_assert "multi-line string cannot leak a loop scope" 0 $E -- 'fn f() {
    let s = "unterminated with loop {
    more";
    info!("fine");
}'
hot_assert "/* */ block comment is not a loop"         0 $E -- 'fn f() {
    /* for x in xs { */
    info!("not in loop");
    /* } */
}'
hot_assert "nested loops on ONE line still flag"       1 $E -- 'fn f() { for a in xs { for b in ys { } info!("outer"); } }'
hot_assert "single-line hot fn flags"                  1 $E -- 'fn tick() { info!("beat"); }'
hot_assert "single-line hot fn (warn!) flags"          1 $E -- 'fn poll() { warn!("w"); }'
hot_assert "for with { on the NEXT line still flags"   1 $E -- 'fn f() {
    for x in xs
    {
        info!("in loop");
    }
}'
hot_assert "guardrails-ok inside a MESSAGE does not suppress" 1 $E -- 'fn f() {
    loop {
        info!("guardrails-ok in the msg");
    }
}'
hot_assert "lifetime tick is not a char literal"       1 $E -- 'fn f<'"'"'a>(x: &'"'"'a str) {
    loop {
        info!("tick");
    }
}'

# DETERMINISM: identical input must yield byte-identical output.
printf 'fn f() {\n    loop {\n        info!("tick");\n    }\n}\n' > "$tmp/hot/h.rs"
h1="$("$hot_gate" "$tmp/hot/h.rs" 2>&1)"; h2="$("$hot_gate" "$tmp/hot/h.rs" 2>&1)"
if [ "$h1" = "$h2" ] && printf '%s' "$h1" | grep -q ':3:info!("tick")'; then
  echo "ok    — hot-info report is deterministic AND names the right line"
else echo "FAIL  — hot-info report nondeterministic or wrong ($h1)"; fails=$((fails + 1)); fi

# --- log-budget: measured per-event budgets over a representative JSONL log ---------
# The only gate that reads a LOG, not source — so it is the only one that can see BOTH a facade-
# hidden fire hose (max_pct) and an operation that emitted NOTHING (require). Absence is checkable
# only against an enumerable population; the budgets file IS that population.
lb_gate="$here/log-budget.sh"
mkdir -p "$tmp/lb"
lb_run() { ( cd "$tmp/lb" && env "$@" "$lb_gate" log-budgets.toml >/dev/null 2>&1 ); }
lb_check() { # desc, want-exit, env...
  local desc="$1" want="$2"; shift 2
  lb_run "$@"
  if [ "$?" = "$want" ]; then echo "ok    — $desc"; else echo "FAIL  — $desc"; fails=$((fails + 1)); fi
}
# A stream where one event is 80% of the records.
: > "$tmp/lb/sample.jsonl"
i=0; while [ $i -lt 8 ]; do printf '{"event":"client.tick","level":"INFO"}\n' >> "$tmp/lb/sample.jsonl"; i=$((i+1)); done
printf '{"event":"app.startup","level":"INFO"}\n' >> "$tmp/lb/sample.jsonl"
printf '{"event":"app.shutdown","level":"INFO"}\n' >> "$tmp/lb/sample.jsonl"

# No budgets file at all → skip silently (zero day-one noise in every consumer of the flake).
rm -f "$tmp/lb/log-budgets.toml"
lb_check "no budgets file → skip (exit 0)" 0 IGNORE=1

printf 'sample = "sample.jsonl"\ndefault_max_pct = 5.0\n' > "$tmp/lb/log-budgets.toml"
lb_check "event over default_max_pct is gated" 1 IGNORE=1
printf 'sample = "sample.jsonl"\ndefault_max_pct = 90.0\n' > "$tmp/lb/log-budgets.toml"
lb_check "event under default_max_pct passes" 0 IGNORE=1
# Per-event override + mode.
printf 'sample = "sample.jsonl"\ndefault_max_pct = 15.0\n\n[event."client.tick"]\nmax_pct = 95.0\n' > "$tmp/lb/log-budgets.toml"
lb_check "per-event max_pct override raises the ceiling" 0 IGNORE=1
printf 'sample = "sample.jsonl"\ndefault_max_pct = 15.0\n\n[event."client.tick"]\nmax_pct = 1.0\nmode = "nudge"\n' > "$tmp/lb/log-budgets.toml"
lb_check "mode=nudge reports without failing" 0 IGNORE=1
lb_check "GUARDRAILS_LOG_ENFORCE=1 promotes a nudge" 1 GUARDRAILS_LOG_ENFORCE=1
# ABSENCE — the direction no source-scanning gate can express.
printf 'sample = "sample.jsonl"\ndefault_max_pct = 95.0\n\n[require."client.slot.flipped"]\nmin_count = 1\n' > "$tmp/lb/log-budgets.toml"
lb_check "required-but-absent event is gated" 1 IGNORE=1
printf 'sample = "sample.jsonl"\ndefault_max_pct = 95.0\n\n[require."app.startup"]\nmin_count = 1\n' > "$tmp/lb/log-budgets.toml"
lb_check "required-and-present event passes" 0 IGNORE=1
printf 'sample = "sample.jsonl"\ndefault_max_pct = 95.0\n\n[require."app.startup"]\nmin_count = 5\n' > "$tmp/lb/log-budgets.toml"
lb_check "required event below min_count is gated" 1 IGNORE=1
# Robustness: a live log has a truncated tail; never crash on it.
cp "$tmp/lb/sample.jsonl" "$tmp/lb/torn.jsonl"
printf '{"event":"app.star\n' >> "$tmp/lb/torn.jsonl"
printf 'sample = "torn.jsonl"\ndefault_max_pct = 95.0\n' > "$tmp/lb/log-budgets.toml"
lb_check "truncated JSON tail is tolerated" 0 IGNORE=1
# Missing sample → skip, not fail (CI without a workload must not go red).
printf 'sample = "nope.jsonl"\ndefault_max_pct = 5.0\n' > "$tmp/lb/log-budgets.toml"
lb_check "missing sample log → skip (exit 0)" 0 IGNORE=1
# Fallback identity when the repo has no canonical event field yet.
printf '{"target":"app","message":"hello"}\n{"target":"app","message":"hello"}\n{"target":"app","message":"bye"}\n' > "$tmp/lb/noev.jsonl"
printf 'sample = "noev.jsonl"\ndefault_max_pct = 50.0\n' > "$tmp/lb/log-budgets.toml"
lb_check "falls back to target+message identity" 1 IGNORE=1
# ...and the identity must be the REAL composite, not a lump-everything-together bucket: an exit
# code alone would pass even if the fallback collapsed all records into one <unidentified> event.
fb="$( cd "$tmp/lb" && "$lb_gate" log-budgets.toml 2>/dev/null )"
if printf '%s' "$fb" | grep -q 'app:hello' && ! printf '%s' "$fb" | grep -q 'unidentified'; then
  echo "ok    — fallback identity names target+message, not a lump bucket"
else echo "FAIL  — fallback identity wrong ($fb)"; fails=$((fails + 1)); fi
# CONFIG ERRORS: a user typo must be a clear message with exit 2, never a Python traceback and
# never a silent downgrade. exit 2 is deliberately distinct from a budget failure's exit 1.
lb_traceback() { # desc, toml
  printf '%s\n' "$2" > "$tmp/lb/log-budgets.toml"
  out="$( cd "$tmp/lb" && "$lb_gate" log-budgets.toml 2>&1 )"
  if printf '%s' "$out" | grep -q 'Traceback'; then
    echo "FAIL  — $1 (python traceback reached the user)"; fails=$((fails + 1))
  else echo "ok    — $1"; fi
}
lb_traceback "non-numeric max_pct is a clean error"    'sample = "sample.jsonl"
[event."client.tick"]
max_pct = "big"'
lb_traceback "non-numeric default_max_pct is clean"    'sample = "sample.jsonl"
default_max_pct = "big"'
lb_traceback "non-numeric min_count is clean"          'sample = "sample.jsonl"
[require."x"]
min_count = "five"'
lb_traceback "scalar [event] entry is a clean error"   'sample = "sample.jsonl"
[event]
any = 42'
lb_check "config error exits 2, not 1" 2 IGNORE=1
# An unrecognised mode used to fall through to nudge — silently disabling enforcement on the very
# entry the author wrote to enforce.
printf 'sample = "sample.jsonl"\ndefault_max_pct = 1.0\n\n[event."client.tick"]\nmode = "Gate"\n' > "$tmp/lb/log-budgets.toml"
lb_check "misspelled mode is rejected, not downgraded" 2 IGNORE=1
# `[require]` + `x = 5` is a natural mistake for `[require."x"] min_count = 5`.
printf 'sample = "sample.jsonl"\ndefault_max_pct = 99.0\n\n[require]\nheartbeat = 5\n' > "$tmp/lb/log-budgets.toml"
lb_check "bare [require] scalar is rejected, not coerced" 2 IGNORE=1
# A ceiling for an event that never appears is usually a typo — warn, but do not fail.
printf 'sample = "sample.jsonl"\ndefault_max_pct = 99.0\n\n[event."cleint.tick"]\nmax_pct = 1.0\n' > "$tmp/lb/log-budgets.toml"
w="$( cd "$tmp/lb" && "$lb_gate" log-budgets.toml 2>&1 >/dev/null )"; wec=$?
if [ "$wec" = 0 ] && printf '%s' "$w" | grep -q 'cleint.tick'; then
  echo "ok    — ceiling for an absent event warns without failing"
else echo "FAIL  — absent-event ceiling silent or fatal ($wec: $w)"; fails=$((fails + 1)); fi
# The summary counter must not contradict the rows printed above it.
printf 'sample = "sample.jsonl"\ndefault_max_pct = 1.0\n\n[event."client.tick"]\nmax_pct = 0.5\nmode = "nudge"\n' > "$tmp/lb/log-budgets.toml"
c="$( cd "$tmp/lb" && "$lb_gate" log-budgets.toml 2>&1 )"
if printf '%s' "$c" | grep -q 'nudge-mode'; then echo "ok    — summary accounts for nudge-mode findings"
else echo "FAIL  — summary under-counts mixed findings ($c)"; fails=$((fails + 1)); fi

# DETERMINISM.
printf 'sample = "sample.jsonl"\ndefault_max_pct = 5.0\n' > "$tmp/lb/log-budgets.toml"
l1="$( cd "$tmp/lb" && "$lb_gate" log-budgets.toml 2>&1 )"
l2="$( cd "$tmp/lb" && "$lb_gate" log-budgets.toml 2>&1 )"
# Determinism alone is satisfied by any consistently-broken gate, so assert the CONTENT too.
if [ "$l1" = "$l2" ] && printf '%s' "$l1" | grep -q 'client.tick: 80.0% of 10 records (8)'; then
  echo "ok    — log-budget report is deterministic AND correct"
else echo "FAIL  — log-budget report nondeterministic or wrong ($l1)"; fails=$((fails + 1)); fi

# =============================================================================================
# dead-event — a DECLARED event emitter with no call site (issue #56)
# =============================================================================================
de_gate="$here/dead-event.sh"
de_root="$tmp/de"

# de_assert <desc> <want-exit> <ENV=v...> -- <facade-body> [<caller-body>]
#   Rebuilds a two-file crate each time so state can't leak between cases.
de_assert() {
  local desc="$1" want="$2"; shift 2
  local env=()
  while [ "$1" != "--" ]; do env+=("$1"); shift; done
  shift
  rm -rf "$de_root"; mkdir -p "$de_root/src"
  printf '%s\n' "$1" > "$de_root/src/facade.rs"
  printf '%s\n' "${2:-}" > "$de_root/src/app.rs"
  ( cd "$de_root" && env "${env[@]}" "$de_gate" . >/dev/null 2>&1 )
  local got=$?
  if [ "$got" = "$want" ]; then echo "ok    — $desc"
  else echo "FAIL  — $desc (want exit $want, got $got)"; fails=$((fails + 1)); fi
}
DE=GUARDRAILS_DEADEVENT_ENFORCE=1

# ADOPTION COSTS NOTHING: no marker => no population => silent success, even under ENFORCE.
# This is the log-budget discipline (no budgets file -> skip), and it is what lets the gate ship
# in the shared flake without every consumer repo lighting up red on day one.
de_assert "no marker anywhere is a silent skip"        0 $DE -- 'pub fn emit_x() {}'

# THE POPULATION IS DECLARED, NOT INFERRED (CONVENTIONS §"what declares the population?").
de_assert "declared + uncalled is caught"              1 $DE -- '// guardrails:events
pub fn emit_x() {}'
de_assert "declared + called is clean"                 0 $DE -- '// guardrails:events
pub fn emit_x() {}' 'fn run() { emit_x(); }'
# A private fn in a facade file is a helper, not an event.
de_assert "non-pub fn is not in the population"        0 $DE -- '// guardrails:events
fn helper() {}'

# EVERY pub form, at every indentation. Matching only `pub(crate) fn` — the shape the motivating
# consumer happened to use — would print green on a facade written with plain `pub fn`: the silent
# no-op that made adr-matrix report 5 Accepted ADRs where there were 43.
for vis in 'pub' 'pub(crate)' 'pub(super)' 'pub(in crate::log)'; do
  de_assert "population includes '$vis fn'"            1 $DE -- "// guardrails:events
$vis fn emit_x() {}"
done
de_assert "population includes an impl-block method"   1 $DE -- '// guardrails:events
impl Facade {
    pub(crate) fn emit_x(&self) {}
}'

# REGION FORM: a facade module inside a bigger file.
de_assert "outside a begin/end region is not declared" 0 $DE -- 'pub fn emit_outside() {}
// guardrails:events-begin
// guardrails:events-end'
de_assert "inside a begin/end region IS declared"      1 $DE -- '// guardrails:events-begin
pub fn emit_inside() {}
// guardrails:events-end'

# THE PROJECTION MUST NOT COUNT COMMENTS OR STRINGS. A `/// see emit_x` doc line on the facade
# itself, or the name inside a message literal, would otherwise suppress the finding — the gate
# would report green on exactly the dead emitter it exists to find.
de_assert "a doc-comment mention is not a call site"   1 $DE -- '// guardrails:events
/// See emit_x for the planned shape.
pub fn emit_x() {}'
de_assert "a string-literal mention is not a call site" 1 $DE -- '// guardrails:events
pub fn emit_x() {}' 'fn run() { let _ = "emit_x was here"; }'

# ...but a WHOLE-WORD reference that is not a call still counts. A well-factored emitter is often
# wired as a value (`.map(emit_x)`), which a call-shaped `emit_x\s*\(` projection would miss and
# report as dead — a false positive on correct, idiomatic code.
de_assert "a fn-value reference counts as wired"       0 $DE -- '// guardrails:events
pub fn emit_x() {}' 'fn run() { let f = emit_x; f(); }'
de_assert "a use-import counts as wired"               0 $DE -- '// guardrails:events
pub fn emit_x() {}' 'use crate::facade::emit_x;'
# Substring collisions must NOT count (`emit_xyz` does not wire `emit_x`).
de_assert "a substring match does not count as wired"  1 $DE -- '// guardrails:events
pub fn emit_x() {}' 'fn run() { emit_xyz(); }'

# A TEST-ONLY CALLER IS STILL DEAD — deliberately, and the OPPOSITE of why the other gates skip
# tests/: nothing wired the event in production. Pinned so nobody "fixes" it back.
mkdir -p "$de_root/tests" 2>/dev/null || true
rm -rf "$de_root"; mkdir -p "$de_root/src" "$de_root/tests"
printf '%s\n' '// guardrails:events
pub fn emit_x() {}' > "$de_root/src/facade.rs"
printf '%s\n' 'fn t() { emit_x(); }' > "$de_root/tests/it.rs"
( cd "$de_root" && GUARDRAILS_DEADEVENT_ENFORCE=1 "$de_gate" . >/dev/null 2>&1 )
if [ $? = 1 ]; then echo "ok    — a tests/-only caller is still dead"
else echo "FAIL  — a tests/-only caller was counted as wired"; fails=$((fails + 1)); fi

# ESCAPES: both conventions (own line, and the pure-comment line above — rustfmt wraps over-long
# trailing comments onto the NEXT line, where they would suppress nothing).
de_assert "guardrails-ok on the fn line suppresses"    0 $DE -- '// guardrails:events
pub fn emit_x() {} // guardrails-ok: planned for v2'
de_assert "guardrails-ok on the line ABOVE suppresses" 0 $DE -- '// guardrails:events
// guardrails-ok(dead-event): emitted via the metrics! macro
pub fn emit_x() {}'

# NUDGE CONTRACT: findings do not fail by default; the ENFORCE knob promotes.
de_assert "findings are a NUDGE by default (exit 0)"   0 -- '// guardrails:events
pub fn emit_x() {}'

# =============================================================================================
# CROSS-GATE CONFORMANCE MATRIX (issue #55) — pin the INVARIANT, not the code.
#
# #55 asked whether to extract the duplicated files()/allowed_file()/guardrails-ok preamble. The
# answer stayed NO (see docs/CONVENTIONS.md §"Duplication with a conformance matrix"), so what
# has to exist instead is a matrix every copy is checked against — because #57 proved the real
# cost of the duplication: hot-info.sh carried the bash-3.2 fix WITH a comment explaining the
# hazard, while two sibling copies still crashed. A per-gate, hand-written test did not catch
# that; a table where a new gate is enrolled by adding ONE ROW does.
#
# Row: <gate-script> <glob-env-var> <extra-env-to-force-enforcement> <fixture>
# =============================================================================================
conf_rows=(
  "no-debug-leftovers.sh|GUARDRAILS_OUTPUT_GLOBS|GUARDRAILS_CONF_NOOP=1|fn f() { println!(\"x\"); }"
  "no-raw-trace-fields.sh|GUARDRAILS_TRACE_ALLOW_GLOBS|GUARDRAILS_CONF_NOOP=1|fn f() { info!(?user); }"
  "hot-info.sh|GUARDRAILS_HOTINFO_ALLOW|GUARDRAILS_HOTINFO_ENFORCE=1|fn f() { loop { info!(\"t\"); } }"
)

conf_root="$tmp/conf"
for row in "${conf_rows[@]}"; do
  IFS='|' read -r cg cvar cenf cfix <<< "$row"
  cgate="$here/$cg"
  rm -rf "$conf_root"; mkdir -p "$conf_root/vendored" "$conf_root/src/vendored"
  printf '%s\n' "$cfix" > "$conf_root/vendored/gen.rs"
  cp "$conf_root/vendored/gen.rs" "$conf_root/src/vendored/gen.rs"

  # (i) The fixture must actually be CAUGHT with no glob set. Without this, every assertion
  #     below passes vacuously on a gate that flags nothing at all.
  ( cd "$conf_root" && env "$cenf" "$cgate" ./vendored/gen.rs >/dev/null 2>&1 )
  if [ $? = 1 ]; then echo "ok    — [$cg] fixture is caught with no glob set"
  else echo "FAIL  — [$cg] fixture NOT caught — the rows below prove nothing"; fails=$((fails + 1)); fi

  # (ii)+(iii) The ./-prefix normalization: dir-walk mode prefixes every path with `./`, so a
  #     configured glob WITHOUT a leading `*` must still match. A gate that gets this wrong
  #     silently no-ops its allow-glob — the knob looks wired and does nothing.
  ( cd "$conf_root" && env "$cenf" "$cvar=vendored/*" "$cgate" ./vendored/gen.rs >/dev/null 2>&1 )
  if [ $? = 0 ]; then echo "ok    — [$cg] glob without a leading * matches a ./-prefixed path"
  else echo "FAIL  — [$cg] ./-prefix normalization missing"; fails=$((fails + 1)); fi
  ( cd "$conf_root" && env "$cenf" "$cvar=*/vendored/*" "$cgate" ./src/vendored/gen.rs >/dev/null 2>&1 )
  if [ $? = 0 ]; then echo "ok    — [$cg] glob with a leading * matches a nested path"
  else echo "FAIL  — [$cg] leading-* glob broken"; fails=$((fails + 1)); fi

  # (iv) An EMPTY knob must neither crash nor allow everything. `IFS=: read -ra a <<< ""` yields
  #      an empty array, and `:`-boundary empties ("a::b") must not glob-match every path.
  ( cd "$conf_root" && env "$cenf" "$cvar=" "$cgate" ./vendored/gen.rs >/dev/null 2>&1 )
  if [ $? = 1 ]; then echo "ok    — [$cg] an empty glob knob does not allow everything"
  else echo "FAIL  — [$cg] an empty glob knob swallowed the finding"; fails=$((fails + 1)); fi
done

# --- bash 3.2 empty-array hazard (issue #57): a SHAPE lint, not a behaviour probe -------------
# `set -u` + an EMPTY array: bash 3.2 (stock macOS /bin/bash, 3.2.57) errors on "${arr[@]}";
# bash 5 does not — which is why `#!/usr/bin/env bash` hid this everywhere a Nix/Homebrew bash
# was on PATH, and why CI (ubuntu, bash 5) could never see it. `BASH_COMPAT=3.2` and
# `shopt -s compat32` do NOT restore the old behaviour, so a behaviour probe is unrunnable on
# the CI runner. The invariant is therefore checked STRUCTURALLY, on any bash: every array built
# by `read -ra` (the only ones here that can legitimately be empty) must be expanded through a
# guard — `${a[@]+"${a[@]}"}` or `"${a[@]:-}"` — at every site.
#
# This is also the answer to "a behaviour test can pass vacuously": an early-return that skips
# the loop would satisfy a runtime probe while leaving the unguarded expansion in place. A shape
# lint cannot be satisfied vacuously.
unguarded="$(
  for g in "$here"/*.sh; do
    case "$(basename "$g")" in test-*) continue ;; esac
    awk -v F="$(basename "$g")" '
      match($0, /read[[:space:]]+-r?a[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/) {
        seg = substr($0, RSTART, RLENGTH); sub(/^.*[[:space:]]/, "", seg); arr[seg] = 1
      }
      { line[NR] = $0 }
      END {
        for (n in arr) {
          guarded = "${" n "[@]+\"${" n "[@]}\"}"
          bare    = "\"${" n "[@]}\""
          for (i = 1; i <= NR; i++) {
            s = line[i]
            while ((p = index(s, guarded)) > 0) s = substr(s, 1, p - 1) substr(s, p + length(guarded))
            if (index(s, bare) > 0) printf "%s:%d: %s\n", F, i, n
          }
        }
      }
    ' "$g"
  done
)"
if [ -z "$unguarded" ]; then
  echo "ok    — every read -ra array is expanded through a bash-3.2-safe guard"
else
  echo "FAIL  — unguarded \"\${arr[@]}\" (crashes stock bash 3.2 under set -u):"
  printf '%s\n' "$unguarded" | sed 's/^/        /'
  fails=$((fails + 1))
fi

# Belt to that suspender: if a real bash 3.x is on this host (macOS ships one at /bin/bash),
# run every gate through it with an EMPTY environment — the reproducer from #57 verbatim.
b32=""
for cand in /bin/bash /usr/bin/bash; do
  [ -x "$cand" ] || continue
  case "$("$cand" -c 'echo $BASH_VERSION' 2>/dev/null)" in 3.*) b32="$cand"; break ;; esac
done
if [ -z "$b32" ]; then
  echo "skip  — no bash 3.x on this host; the shape lint above is the portable check"
else
  mkdir -p "$tmp/b32"; printf 'fn f() { info!("x"); println!("y"); }\n' > "$tmp/b32/c.rs"
  b32_bad=""
  for g in "$here"/*.sh; do
    case "$(basename "$g")" in test-*|protect-trunk*) continue ;; esac  # protect-trunk-push reads stdin
    o="$(env -i PATH=/usr/bin:/bin HOME="$tmp" "$b32" "$g" "$tmp/b32/c.rs" 2>&1 </dev/null)"
    case "$o" in *"unbound variable"*) b32_bad="$b32_bad $(basename "$g")" ;; esac
  done
  if [ -z "$b32_bad" ]; then echo "ok    — every gate runs under bash 3.x with an empty environment"
  else echo "FAIL  — gate(s) crash on bash 3.x:$b32_bad"; fails=$((fails + 1)); fi
fi

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails test(s) FAILED" >&2
  exit 1
fi
echo "all gate tests passed"
