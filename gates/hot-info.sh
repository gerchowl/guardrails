#!/usr/bin/env bash
# guardrails: hot-info nudge — `info!`/`warn!` on a per-iteration path (level vs FREQUENCY).
#
# docs/CONVENTIONS.md states the level contract and names the failure mode: "the one rule agents
# break: frequency dictates level … info — LOW-FREQUENCY lifecycle events. Never per-iteration."
# Until now nothing checked it. An INFO inside a render loop or a poll tick turns the audit trail
# into a fire hose: real consumers measured at 97% of the log being ONE heartbeat event, ~15MB/day,
# with a full day's actual signal fitting in 63 lines.
#
# Detection is LEXICAL and therefore a HEURISTIC: an `info!` in a startup loop that runs three times
# is correct code and WILL be flagged. That is why this is a NUDGE (report, exit 0) and why it does
# NOT participate in the nudge-ledger's age-based auto-promotion — that mechanism is only sound for
# a precision-first check (see duplication.sh: "an EXACT >=K normalized-line match is a real clone,
# so noise stays near zero"). A false positive is never "fixed", so it would age into a hard block
# on correct code. Promotion here is a deliberate per-repo choice: GUARDRAILS_HOTINFO_ENFORCE=1.
#
# KNOWN LIMIT, stated rather than papered over: this sees LEXICAL nesting, not call frequency. A
# facade — one function per event, called from a loop in another file — is INVISIBLE to it. In the
# consumer that motivated this gate the `info!` sits in a helper whose call site is 671 lines below
# its enclosing loop, one hop away in a different file. No bash scanner reaches that. The measured
# `log-budget` gate is the instrument that does; this one catches the naive case at WRITE time,
# before a log exists to measure. They are complementary, and neither replaces the other.
#
# The escape hatch is the deliverable. Annotating `// guardrails-ok(hot-info): startup, runs 3x`
# is a diff-visible declaration a reviewer can weigh — the value is forced deliberation, not caught
# mistakes. A BARE `guardrails-ok` still suppresses (house convention) but is reported as an
# undocumented exemption so the reviewer sees it.
#
# Usage: guardrails-hot-info [paths...]      (default: .)
#   GUARDRAILS_HOTINFO_ALLOW    colon-separated path globs skipped wholesale
#   GUARDRAILS_HOTINFO_ENFORCE=1  promote from nudge (exit 0) to hard gate (exit 1)
set -uo pipefail

case "${1:-}" in -h | --help) sed -n '2,/^set /p' "$0" | sed 's/^# \{0,1\}//; /^set /d'; exit 0 ;; esac

roots=("${@:-.}")
hits=0
bare=0

IFS=: read -ra allow_globs <<< "${GUARDRAILS_HOTINFO_ALLOW:-}"

allowed_file() {
  # Dir-walks arrive './'-prefixed; normalize so allow-globs without a leading '*' still match.
  # test-gates.sh pins this — every gate taking path globs must do it.
  set -- "${1#./}"
  case "$1" in *gates/*|tests/*|*/tests/*|*_test.*|*.test.*|examples/*|*/examples/*) return 0 ;; esac
  local g
  for g in "${allow_globs[@]}"; do
    [ -n "$g" ] || continue
    # shellcheck disable=SC2254 -- $g is intentionally a glob pattern
    case "$1" in $g) return 0 ;; esac
  done
  return 1
}

files() {
  for p in "$@"; do
    if [ -d "$p" ]; then git -C "$p" ls-files 2>/dev/null | sed "s#^#${p%/}/#" || find "$p" -type f
    elif [ -f "$p" ]; then echo "$p"; fi
  done
}

# One awk pass per file. Tracks brace depth and, per depth, WHY that brace opened (loop / hot-named
# fn / other) so a macro can ask "is any enclosing scope hot?". Same idiom as no-hardcoded.sh's
# intest/intunable depth tracking: strip comments and blank string+char literals on a scratch copy,
# then count braces. Inherits that approach's limits (escaped quotes, raw strings) — acceptable for
# a nudge, where a miss costs an annotation rather than a broken build.
scan() {
  awk '
  function hot_name(s) {
    return (s ~ /(^|[^a-zA-Z0-9_])fn[ \t]+(tick|poll|sample|heartbeat|render|on_frame|on_tick|step|update)[a-zA-Z0-9_]*[ \t]*[(<]/)
  }
  function is_loop(s) {
    return (s ~ /(^|[^a-zA-Z0-9_])(loop|while|for)([^a-zA-Z0-9_]|$)/)
  }
  function braces(s, ch, n) { n = gsub(ch, "", s); return n }
  # Tail of s after its LAST loop keyword — so brace balance is measured from the loop, not from
  # the start of the line (where an enclosing fn`s own `{` would leak in).
  function after_last_loop(s,   rest, tail) {
    rest = s; tail = ""
    while (match(rest, /(^|[^a-zA-Z0-9_])(loop|while|for)([^a-zA-Z0-9_]|$)/)) {
      tail = substr(rest, RSTART + RLENGTH - 1)
      rest = tail
    }
    return tail
  }
  {
    raw = $0
    body = raw
    sub(/\/\/.*/, "", body)          # drop line comment
    gsub(/"[^"]*"/, "", body)        # blank simple string literals
    gsub(/'\''\\?.'\''/, "", body)   # blank char literals

    pending_loop = is_loop(body) ? 1 : 0
    pending_hot  = hot_name(body) ? 1 : 0

    # Does a macro appear on this line, and is it inside a loop opened EARLIER ON THIS SAME LINE?
    # `for x in xs { info!() }` must flag; `for _ in xs { } info!()` must not. Compare brace balance
    # in the prefix before the macro rather than guessing from the whole line.
    flag_same_line = 0
    if (match(body, /(^|[^a-zA-Z0-9_])(info|warn)![ \t]*\(/)) {
      prefix = substr(body, 1, RSTART)
      if (is_loop(prefix)) {
        tail = after_last_loop(prefix)
        o = tail; c = tail
        if (braces(o, "{") > braces(c, "}")) flag_same_line = 1
      }
      has_macro = 1
    } else has_macro = 0

    # Is any ENCLOSING scope (opened on a previous line) hot?
    in_hot = 0
    for (d = 1; d <= depth; d++) if (kind[d] == "loop" || kind[d] == "hot") { in_hot = 1; break }

    if (has_macro && (in_hot || flag_same_line)) printf "%d\n", FNR

    # Apply this line'\''s braces AFTER the decision, so a closing brace does not retroactively
    # un-hot a macro that sat inside the block.
    nopen = braces(body, "{"); nclose = braces(body, "}")
    for (i = 0; i < nopen; i++) {
      depth++
      kind[depth] = pending_loop ? "loop" : (pending_hot ? "hot" : "other")
      pending_loop = 0; pending_hot = 0
    }
    for (i = 0; i < nclose; i++) { if (depth > 0) { delete kind[depth]; depth-- } }
  }
  ' "$1"
}

while IFS= read -r f; do
  case "$f" in *.rs) ;; *) continue ;; esac
  allowed_file "$f" && continue
  [ -f "$f" ] || continue
  while IFS= read -r no; do
    [ -n "$no" ] || continue
    line="$(sed -n "${no}p" "$f")"
    case "$line" in *guardrails-ok*)
      case "$line" in *guardrails-ok\(*|*guardrails-ok:*) ;; *) bare=$((bare + 1)) ;; esac
      continue ;;
    esac
    # Own-line marker ABOVE the hit: rustfmt wraps over-long trailing comments onto the NEXT line
    # (where they suppress nothing), so a pure-comment line above is the stable convention.
    if [ "$no" -gt 1 ]; then
      prev="$(sed -n "$((no - 1))p" "$f")"
      case "$prev" in
        *//*guardrails-ok*)
          case "$prev" in *guardrails-ok\(*|*guardrails-ok:*) ;; *) bare=$((bare + 1)) ;; esac
          continue ;;
      esac
    fi
    printf '  %s:%s:%s\n' "$f" "$no" "$(printf '%s' "$line" | sed 's/^[[:space:]]*//')"
    hits=$((hits + 1))
  done < <(scan "$f")
done < <(files "${roots[@]}")

[ "$bare" = 0 ] || echo "guardrails/hot-info: $bare undocumented 'guardrails-ok' exemption(s) — give each a reason." >&2

[ "$hits" -gt 0 ] || exit 0

msg="$hits info!/warn! call(s) on an apparent per-iteration path — use debug!/trace!, or annotate with a reason (frequency dictates level; see docs/CONVENTIONS.md)"

if [ "${GUARDRAILS_HOTINFO_ENFORCE:-}" = "1" ]; then
  echo "guardrails/hot-info: $msg" >&2
  exit 1
fi

echo "nudge: $msg" >&2
exit 0
