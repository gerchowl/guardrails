#!/usr/bin/env bash
# guardrails: dead-event nudge — a DECLARED event emitter with zero call sites (issue #56).
#
# The narrow, cheap slice of the absence problem. docs/CONVENTIONS.md states the rule: "Presence is
# greppable; absence is not … Absence becomes checkable only when you can enumerate what should have
# been there". `log-budget` does that with a TOML enumerating required events — but it needs a
# CAPTURED LOG, so it runs late (CI / post-workload). This one needs no log and runs at commit time:
#
#   Population  every `pub`-visible `fn` inside a region a human DECLARED as the event facade.
#   Projection  each such name is referenced at least once outside its own definition line.
#
# Same shape as `adr-matrix` (Accepted ADRs → cited in the matrix) and `derived-docs` (marked region
# → matches its generator). Catches a real drift class: an event family written, documented,
# levelled — and then never wired up. In the consumer that motivated #53 the logging facade is
# ~4800 lines; a dead emitter in there is invisible to review.
#
# WHAT DECLARES THE POPULATION — the load-bearing design choice. An earlier draft reused
# `GUARDRAILS_TRACE_ALLOW_GLOBS` (no-raw-trace-fields' allowlist) to locate the facade file. That is
# a COINCIDENCE, not a declaration: it is an EXCLUSION list read as an INCLUSION list, it silently
# skips every repo that has not set it, and it captures unrelated `pub fn`s that share the file. Per
# CONVENTIONS §"what declares the population?", the honest form is an author-placed marker:
#
#   // guardrails:events                    → the whole FILE is the event facade
#   // guardrails:events-begin … -end       → just that region (a facade module inside a bigger file)
#
# One diff-visible line of intent. No env var, no cross-gate coupling, and a repo with no marker is
# simply not opted in — the gate exits 0 silently, so adopting the flake costs nothing (same
# discipline as `log-budget` with no budgets file).
#
# RESIDUAL FALSE POSITIVES — stated, not papered over. This is why v1 is a NUDGE:
#   · macro-generated callers (`emit_family!(a, b)` expanding to `emit_a(); emit_b();`) — the name
#     never appears literally, so a wired emitter reads as dead.
#   · a PUBLISHED LIBRARY whose callers live in downstream crates: every event looks dead. Don't
#     mark a published facade, or promote nothing and read the nudge as informational.
#   · a caller reachable only from `tests/` counts as DEAD here — deliberately, and note this is the
#     OPPOSITE of why the other gates skip tests: a test-only caller means nothing wired it in
#     production. That is the defect, not an exemption.
# And the conservative direction: any whole-word mention outside the definition line counts as
# wired (a `pub use` re-export, a `mod` listing). The gate UNDER-reports rather than crying wolf.
#
# Rust-only (`fn` parsing). Escape: `guardrails-ok` on the fn's own line, or on a pure `//` comment
# line directly above it (stable under rustfmt's comment wrapping) — same convention as hot-info.
#
# Usage: guardrails-dead-event [paths...]      (default: .)
#   GUARDRAILS_DEADEVENT_ENFORCE=1   promote from nudge (exit 0) to hard gate (exit 1)
set -uo pipefail

case "${1:-}" in -h | --help) sed -n '2,/^set /p' "$0" | sed 's/^# \{0,1\}//; /^set /d'; exit 0 ;; esac

roots=("${@:-.}")

files() {
  for p in "$@"; do
    if [ -d "$p" ]; then git -C "$p" ls-files 2>/dev/null | sed "s#^#${p%/}/#" || find "$p" -type f
    elif [ -f "$p" ]; then echo "$p"; fi
  done
}

# The corpus is EVERY tracked Rust file minus the standard built-in exemptions — deliberately NOT
# narrowable by an allow-glob. Shrinking the corpus here would hide CALL SITES, i.e. manufacture
# false positives; the only knob that could help is one that makes the gate lie.
corpus_skip() {
  set -- "${1#./}"
  case "$1" in *gates/*|tests/*|*/tests/*|*_test.*|*.test.*|examples/*|*/examples/*) return 0 ;; esac
  return 1
}

corpus=()
while IFS= read -r f; do
  case "$f" in *.rs) ;; *) continue ;; esac
  corpus_skip "$f" && continue
  [ -f "$f" ] || continue
  corpus+=("$f")
done < <(files "${roots[@]}")

[ "${#corpus[@]}" -gt 0 ] || exit 0

# --- 1. the declared population ------------------------------------------------------------
# Emits: name<TAB>file<TAB>lineno   for every pub-visible `fn` inside a declared facade region.
# Visibility deliberately spans EVERY pub form (`pub`, `pub(crate)`, `pub(super)`, `pub(in ...)`)
# and any indentation, so a facade written as inherent methods in an `impl` block is covered too.
# Matching only `pub(crate) fn` — the shape the motivating consumer happened to use — would print
# green on a facade written with plain `pub fn`: a silent no-op, the exact failure mode that made
# adr-matrix report 5 Accepted ADRs where there were 43.
declared() {
  awk '
  BEGIN { in_region = 0; whole_file = 0; in_block = 0 }
  {
    line = $0
    # Markers are read from the RAW line (they are comments by construction). The tail class
    # keeps `guardrails:eventsource` in some unrelated TODO from silently opting a whole file in.
    if (line ~ /guardrails:events-begin/) { in_region = 1; next }
    if (line ~ /guardrails:events-end/)   { in_region = 0; next }
    if (line ~ /guardrails:events([^-A-Za-z0-9_]|$)/) { whole_file = 1; next }

    if (!whole_file && !in_region) { prev = line; next }

    # Blank /* … */ block comments, carrying state across lines: a `pub fn` inside a commented-out
    # region is not a declaration, and counting it would put a phantom name in the population that
    # can never have a call site — a false positive that is impossible to "fix".
    code = ""; i = 1; n = length(line)
    while (i <= n) {
      c = substr(line, i, 1)
      if (in_block) {
        if (c == "*" && substr(line, i + 1, 1) == "/") { in_block = 0; code = code "  "; i += 2; continue }
        code = code " "; i++; continue
      }
      if (c == "/" && substr(line, i + 1, 1) == "*") { in_block = 1; code = code "  "; i += 2; continue }
      code = code c; i++
    }

    # `guardrails-ok` on this line, or on a pure-comment line directly above, opts one fn out.
    if (line ~ /guardrails-ok/) { prev = line; next }
    if (prev ~ /^[[:space:]]*\/\// && prev ~ /guardrails-ok/) { prev = line; next }

    # Visibility spans EVERY pub form. The `(…)` restriction may be followed by no space at all
    # (`pub(crate)fn`), and the modifier chain between visibility and `fn` admits `const`, `async`,
    # `unsafe` AND the ABI string of `pub extern "C" fn` — all legal Rust, all previously invisible.
    if (match(code, /^[[:space:]]*pub([[:space:]]*\([^)]*\)[[:space:]]*|[[:space:]]+)(([A-Za-z_][A-Za-z0-9_]*|"[^"]*")[[:space:]]+)*fn[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/)) {
      seg = substr(code, RSTART, RLENGTH)
      sub(/^.*[^A-Za-z0-9_]fn[[:space:]]+/, "", seg)
      printf "%s\t%s\t%d\n", seg, FILENAME, FNR
    }
    prev = line
  }
  ' "$1"
}

pop=""
for f in "${corpus[@]}"; do
  grep -q 'guardrails:events' "$f" 2>/dev/null || continue
  pop="$pop$(declared "$f")
"
done

# No marker anywhere → the repo has not opted in. Silent success, like log-budget with no TOML.
pop="$(printf '%s' "$pop" | grep -v '^[[:space:]]*$')" || true
[ -n "$pop" ] || exit 0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf '%s\n' "$pop" > "$work/pop"
cut -f1 "$work/pop" | sort -u > "$work/names"

# --- 2. the projection: where is each name referenced? --------------------------------------
# One awk pass over the whole corpus (not one grep per name — a 4800-line facade declares
# hundreds of names). Comments and string literals are BLANKED first: a `/// see emit_foo` doc
# line on the facade itself would otherwise count as a call site and suppress the finding.
# Blanking is single-line by design; a name mentioned inside a `/* */` block or a multi-line raw
# string still counts as a reference — under-reporting, the safe direction for a nudge.
# Batched through xargs, and the file list is NOT expanded onto one awk command line: a large
# workspace would blow ARG_MAX exactly where the gate is supposed to be most useful.
: > "$work/sightings"
printf '%s\0' "${corpus[@]}" | xargs -0 awk -v names="$work/names" '
  BEGIN { while ((getline n < names) > 0) if (n != "") want[n] = 1 }
  {
    s = $0; n = length(s); out = ""; i = 1
    while (i <= n) {
      c = substr(s, i, 1)
      if (c == "/" && substr(s, i + 1, 1) == "/") break            # // line comment (incl. /// docs)
      if (c == "\"") {                                             # string literal
        j = i + 1
        while (j <= n) { if (substr(s, j, 1) == "\\") { j += 2; continue } if (substr(s, j, 1) == "\"") { j++; break } j++ }
        out = out " "; i = j; continue
      }
      out = out c; i++
    }
    # Walk identifiers in the blanked line; report any that is a declared event name.
    k = 1; m = length(out)
    while (k <= m) {
      ch = substr(out, k, 1)
      if (ch ~ /[A-Za-z_]/ && (k == 1 || substr(out, k - 1, 1) !~ /[A-Za-z0-9_]/)) {
        rest = substr(out, k)
        match(rest, /^[A-Za-z_][A-Za-z0-9_]*/)
        w = substr(rest, 1, RLENGTH)
        if (w in want) printf "%s\t%s\t%d\n", w, FILENAME, FNR
        k += RLENGTH; continue
      }
      k++
    }
  }
'  >> "$work/sightings" || { echo "guardrails/dead-event: projection scan failed — refusing to report a clean bill of health" >&2; exit 2; }

# --- 3. dead = every sighting is its own definition line ------------------------------------
# Single pass, not one awk per name: a 4800-line facade declares hundreds of them, and the
# per-name loop this replaced was O(names x sightings) process spawns.
out="$(awk -F'\t' '
  # Two input files, in order: the declared population, then every sighting of a declared name.
  # Passed as FILES rather than through the environment: a ~4800-line facade declares hundreds of
  # names and tens of thousands of sightings, and `VAR=… awk` dies with E2BIG at that size. The
  # capture would have swallowed the error and reported ZERO dead emitters under ENFORCE — the
  # silent no-op this gate exists to prevent, in the gate itself.
  FNR == NR {
    if ($0 == "") next
    isdef[$1 SUBSEP $2 SUBSEP $3] = 1
    order[++cnt] = $0
    next
  }
  {
    if ($0 == "") next
    if (!(($1 SUBSEP $2 SUBSEP $3) in isdef)) referenced[$1] = 1
  }
  END {
    for (i = 1; i <= cnt; i++) {
      split(order[i], p, FS)
      if (p[1] in referenced) continue
      if (seen[order[i]]++) continue
      printf "  %s:%s:%s\n", p[2], p[3], p[1]
    }
  }
' "$work/pop" "$work/sightings")" || { echo "guardrails/dead-event: reconciliation failed" >&2; exit 2; }

hits="$(printf '%s' "$out" | grep -c . || true)"
[ "${hits:-0}" -gt 0 ] || exit 0

printf '%s\n' "$out"
msg="$hits declared event emitter(s) with no call site — wire them up, delete them, or annotate 'guardrails-ok' with a reason (declared population: 'guardrails:events'; see docs/CONVENTIONS.md)"

if [ "${GUARDRAILS_DEADEVENT_ENFORCE:-}" = "1" ]; then
  echo "guardrails/dead-event: $msg" >&2
  exit 1
fi

echo "nudge: $msg" >&2
exit 0
