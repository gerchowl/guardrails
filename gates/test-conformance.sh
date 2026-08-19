#!/usr/bin/env bash
# Cross-gate CONFORMANCE — the invariants every gate must satisfy, in one table (issue #55).
#
# Split out from test-gates.sh because this is the one part of the suite that must itself run
# under stock bash 3.2: macOS CI executes exactly this file. The rest of test-gates.sh needs
# bash 4 (tools/nudge-ledger.sh uses associative arrays), so pointing the macOS runner at the
# full suite reported 26 failures that were all "this host has no bash 4" — noise that would
# have buried the two real portability bugs the job DID find on day one (#57's runtime twin in
# gates/duplication.sh, which did not even PARSE under bash 3.2, and the harness's own
# `env "${env[@]}"` crash).
#
# Run: gates/test-conformance.sh   (also invoked by gates/test-gates.sh)
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0

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
#
# Scope, stated so the gap is visible rather than assumed away: the lint tracks arrays built by
# `read -ra` and by a bare `name=()`, because those are the two that are EMPTY in the normal case.
# It deliberately accepts a count guard (`[ "${#a[@]}" -gt 0 ]` — legal on bash 3.2) as sufficient,
# since that is the idiom for accumulator arrays. THE HARNESSES ARE LINTED TOO: the macOS CI job
# caught `env "${env[@]}"` crashing right here in test-gates.sh, in code whose whole job is to
# police that class. A lint that exempts itself is how that happened.
lint_arrays() { # $1 = directory of shell scripts
  for g in "$1"/*.sh; do
    awk -v F="$(basename "$g")" '
      # Heredoc BODIES are data, not code: a doc block showing `name=()` and `"${name[@]}"` as an
      # example would otherwise be linted as a defect in the script quoting it.
      hd != "" { line[NR] = ""; t = $0; sub(/^[[:space:]]*/, "", t); sub(/[[:space:]]*$/, "", t); if (t == hd) hd = ""; next }
      match($0, /<<-?[[:space:]]*'"'"'?[A-Za-z_][A-Za-z0-9_]*'"'"'?/) {
        seg = substr($0, RSTART, RLENGTH); gsub(/[<>'"'"'[:space:]-]/, "", seg); hd = seg
      }
      /^[[:space:]]*#/ { line[NR] = ""; next }        # a comment quoting the pattern is not code
      # `read -ra x`, `read -r -a x`, `read -a x` — the flags may be split, so match the whole
      # flag run and then ask whether any of it requested an ARRAY. Matching only `-r?a` let a
      # genuinely-buggy gate written as `read -r -a things` sail past the lint.
      match($0, /(^|[^A-Za-z0-9_])read([[:space:]]+-[A-Za-z]+)+[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/) {
        seg = substr($0, RSTART, RLENGTH)
        nm = seg; sub(/^.*[[:space:]]/, "", nm)
        fl = seg; sub(/[[:space:]]+[A-Za-z_][A-Za-z0-9_]*$/, "", fl)
        if (fl ~ /-[A-Za-z]*a/) arr[nm] = 1
      }
      match($0, /(^|[[:space:]])(local[[:space:]]+|declare[[:space:]]+-a[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=\(\)/) {
        seg = substr($0, RSTART, RLENGTH); sub(/=\(\)$/, "", seg); sub(/^.*[[:space:]]/, "", seg); arr[seg] = 1
      }
      # A count guard makes the array safe to expand — but only when it is actually a TEST.
      # Accepting any mention of ${#a[@]} let a stray `echo "n=${#a[@]}"` exempt every unguarded
      # expansion of that array in the file.
      /\$\{#[A-Za-z_][A-Za-z0-9_]*\[@\]\}/ && /(^|[[:space:]])(if|while|until|\[\[?|\(\()/ {
        s2 = $0
        while (match(s2, /\$\{#[A-Za-z_][A-Za-z0-9_]*\[@\]\}/)) {
          nm = substr(s2, RSTART + 3, RLENGTH - 7); guardedby[nm] = 1
          s2 = substr(s2, RSTART + RLENGTH)
        }
      }
      { line[NR] = $0 }
      END {
        for (n in arr) {
          if (n in guardedby) continue
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
}

unguarded="$(lint_arrays "$here")"
if [ -z "$unguarded" ]; then
  echo "ok    — every possibly-empty array is expanded through a bash-3.2-safe guard"
else
  echo "FAIL  — unguarded \"\${arr[@]}\" (crashes stock bash 3.2 under set -u):"
  printf '%s\n' "$unguarded" | sed 's/^/        /'
  fails=$((fails + 1))
fi

# The lint is itself red-green tested. Every probe below was written by an adversarial reviewer
# against an earlier version and PASSED it — `read -r -a` (flags split, so the old `-r?a` regex
# missed it) is a real bash-3.2 crash the lint waved through.
probe="$tmp/lintprobe"; mkdir -p "$probe"
cat > "$probe/split_flags.sh" <<'PROBE'
IFS=: read -r -a things <<< "${SOME_VAR:-}"
for t in "${things[@]}"; do echo "$t"; done
PROBE
cat > "$probe/safe_countguard.sh" <<'PROBE'
acc=()
acc+=(x)
if [ "${#acc[@]}" -gt 0 ]; then printf '%s\n' "${acc[@]}"; fi
PROBE
cat > "$probe/stray_count_mention.sh" <<'PROBE'
acc=()
echo "size is ${#acc[@]}"
printf '%s\n' "${acc[@]}"
PROBE
cat > "$probe/heredoc_is_data.sh" <<'PROBE'
cat <<'DOC'
Example of the hazard:  demo=()  then  "${demo[@]}"
DOC
PROBE
pl="$(lint_arrays "$probe")"
case "$pl" in *split_flags.sh*) echo "ok    — lint catches \`read -r -a\` with split flags" ;;
  *) echo "FAIL  — lint misses \`read -r -a\` (crashes bash 3.2)"; fails=$((fails + 1)) ;; esac
case "$pl" in *safe_countguard.sh*) echo "FAIL  — lint cries wolf on a count-guarded accumulator"; fails=$((fails + 1)) ;;
  *) echo "ok    — a \${#a[@]} TEST guard is accepted" ;; esac
case "$pl" in *stray_count_mention.sh*) echo "ok    — a non-test \${#a[@]} mention does not exempt" ;;
  *) echo "FAIL  — a stray \${#a[@]} mention wrongly exempted the array"; fails=$((fails + 1)) ;; esac
case "$pl" in *heredoc_is_data.sh*) echo "FAIL  — lint reads heredoc BODY as code"; fails=$((fails + 1)) ;;
  *) echo "ok    — heredoc bodies are data, not code" ;; esac

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
  # PARSE first. The original probe only grepped stderr for "unbound variable", so it reported
  # gates/duplication.sh as OK while that gate could not even be parsed by bash 3.2 (a heredoc
  # nested inside `$( … )` — the parser runs off the end of the file). A gate that does not parse
  # is more broken than one that crashes, and the narrower probe scored it green.
  parse_bad=""
  for g in "$here"/*.sh "$here"/../tools/*.sh; do
    "$b32" -n "$g" 2>/dev/null || parse_bad="$parse_bad $(basename "$g")"
  done
  if [ -z "$parse_bad" ]; then echo "ok    — every gate and tool PARSES under bash 3.x"
  else echo "FAIL  — does not parse on bash 3.x:$parse_bad"; fails=$((fails + 1)); fi

  mkdir -p "$tmp/b32"; printf 'fn f() { info!("x"); println!("y"); }\n' > "$tmp/b32/c.rs"
  b32_bad=""
  for g in "$here"/*.sh; do
    case "$(basename "$g")" in test-*|protect-trunk*) continue ;; esac  # protect-trunk-push reads stdin
    o="$(env -i PATH=/usr/bin:/bin HOME="$tmp" "$b32" "$g" "$tmp/b32/c.rs" 2>&1 </dev/null)"
    case "$o" in
      *"unbound variable"*|*"syntax error"*|*"unexpected"*|*"invalid option"*)
        b32_bad="$b32_bad $(basename "$g")" ;;
    esac
  done
  if [ -z "$b32_bad" ]; then echo "ok    — every gate runs under bash 3.x with an empty environment"
  else echo "FAIL  — gate(s) broken on bash 3.x:$b32_bad"; fails=$((fails + 1)); fi
fi

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails conformance test(s) FAILED" >&2
  exit 1
fi
echo "all conformance tests passed"
