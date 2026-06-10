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

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails test(s) FAILED" >&2
  exit 1
fi
echo "all gate tests passed"
