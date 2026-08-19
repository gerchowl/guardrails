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
  # bash 3.2 (stock macOS) errors on "${arr[@]}" for an EMPTY array under `set -u`; the
  # ${arr[@]+...} guard is the portable form. Without it this gate dies on line one wherever
  # /bin/bash is the interpreter.
  for g in ${allow_globs[@]+"${allow_globs[@]}"}; do
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

# One awk pass per file, as a POSITIONAL lexer rather than a line matcher. Two phases per line:
#
#   A. blank out everything that is not code, CARRYING STATE ACROSS LINES — line comments, /* */
#      block comments, "strings" (with \" escapes), r"…"/r#"…"# raw strings, and 'c' char literals
#      (distinguished from 'lifetime ticks). Positions are preserved 1:1 so phase B's offsets stay
#      meaningful.
#   B. walk the blanked line LEFT TO RIGHT, applying braces and keywords in the order they occur,
#      and evaluate a macro AT ITS OWN POSITION.
#
# Phase B is what makes the tricky cases fall out for free instead of needing special-casing:
# nested loops on one line, a macro after a loop already closed on the same line, a hot fn whose
# whole body is one line, and a `for` whose `{` is on the NEXT line (rustfmt does this constantly)
# all reduce to "what is the brace stack at the macro's offset?".
scan() {
  awk '
  function is_kw(w) { return (w == "loop" || w == "while" || w == "for") }
  function is_hot(w) {
    return (w == "tick" || w == "poll" || w == "sample" || w == "heartbeat" || w == "render" ||
            w == "on_frame" || w == "on_tick" || w == "step" || w == "update")
  }
  function hot_prefixed(w,   i, bases) {
    split("tick poll sample heartbeat render on_frame on_tick step update", bases, " ")
    for (i in bases) if (index(w, bases[i]) == 1) return 1
    return 0
  }
  {
    line = $0
    out = ""
    i = 1
    n = length(line)
    while (i <= n) {
      c = substr(line, i, 1)
      if (st == 2) {                                   # inside /* */
        if (c == "*" && substr(line, i + 1, 1) == "/") { st = 0; out = out "  "; i += 2; continue }
        out = out " "; i++; continue
      }
      if (st == 3) {                                   # inside "…"
        if (c == "\\") { out = out "  "; i += 2; continue }
        if (c == "\"") { st = 0; out = out " "; i++; continue }
        out = out " "; i++; continue
      }
      if (st == 4) {                                   # inside r#*"…"#*
        if (c == "\"") {
          j = i + 1; h = 0
          while (substr(line, j, 1) == "#") { h++; j++ }
          if (h >= raw_h) { st = 0; out = out sprintf("%*s", 1 + raw_h, ""); i = j; continue }
        }
        out = out " "; i++; continue
      }
      # --- normal code ---
      if (c == "/" && substr(line, i + 1, 1) == "/") { while (i <= n) { out = out " "; i++ }; break }
      if (c == "/" && substr(line, i + 1, 1) == "*") { st = 2; out = out "  "; i += 2; continue }
      if (c == "\"") { st = 3; out = out " "; i++; continue }
      if (c == "r" || c == "b") {                      # r"…", r#"…"#, b"…"
        j = i + 1; h = 0
        while (substr(line, j, 1) == "#") { h++; j++ }
        if (substr(line, j, 1) == "\"") { raw_h = h; st = 4; out = out sprintf("%*s", j - i + 1, ""); i = j + 1; continue }
      }
      if (c == "'"'"'") {                              # char literal vs lifetime tick
        if (substr(line, i + 1, 1) == "\\" && substr(line, i + 3, 1) == "'"'"'") { out = out "    "; i += 4; continue }
        if (substr(line, i + 2, 1) == "'"'"'") { out = out "   "; i += 3; continue }
        out = out " "; i++; continue                   # lifetime: harmless to blank the tick
      }
      out = out c; i++
    }
    if (st == 2 || st == 3 || st == 4) { } else st = 0  # line comments end at EOL; others persist

    # --- phase B: walk the blanked line in order ---
    m = length(out)
    k = 1
    while (k <= m) {
      ch = substr(out, k, 1)
      if (ch == "{") {
        depth++
        kind[depth] = pending_loop ? "loop" : (pending_hot ? "hot" : "other")
        pending_loop = 0; pending_hot = 0
        k++; continue
      }
      if (ch == "}") {
        if (depth > 0) { delete kind[depth]; depth-- }
        k++; continue
      }
      if (ch ~ /[A-Za-z_]/ && (k == 1 || substr(out, k - 1, 1) !~ /[A-Za-z0-9_]/)) {
        rest = substr(out, k)
        match(rest, /^[A-Za-z_][A-Za-z0-9_]*/)
        w = substr(rest, 1, RLENGTH)
        after = substr(rest, RLENGTH + 1)
        if (is_kw(w)) pending_loop = 1
        else if (w == "fn") { fn_next = 1 }
        else if (fn_next) { fn_next = 0; if (is_hot(w) || hot_prefixed(w)) pending_hot = 1 }
        else if ((w == "info" || w == "warn") && after ~ /^![ \t]*\(/) {
          hot = 0
          for (d = 1; d <= depth; d++) if (kind[d] == "loop" || kind[d] == "hot") { hot = 1; break }
          if (hot) print FNR
        }
        k += RLENGTH; continue
      }
      k++
    }
  }
  ' "$1" | sort -n | uniq
}

while IFS= read -r f; do
  case "$f" in *.rs) ;; *) continue ;; esac
  allowed_file "$f" && continue
  [ -f "$f" ] || continue
  while IFS= read -r no; do
    [ -n "$no" ] || continue
    line="$(sed -n "${no}p" "$f")"
    # Only a marker in COMMENT position suppresses. Matching the raw line let a caller defeat the
    # gate with `info!("guardrails-ok")` in the message text.
    comment="${line#*//}"
    [ "$comment" = "$line" ] && comment=""
    case "$comment" in *guardrails-ok*)
      case "$comment" in *guardrails-ok\(*|*guardrails-ok:*) ;; *) bare=$((bare + 1)) ;; esac
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
