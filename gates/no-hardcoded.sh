#!/usr/bin/env bash
# guardrails: no bare hardcoded values — wrap them in `const_tunable!` / `config!` so every magic
# value lands in the generated TUNABLES.md (registered + auditable from one file). This is the
# enforcement half of the decorator→registry pattern.
#
# Heuristic (low false-positive, documented): in scanned `crates/*/src/**/*.rs`, flags
#   * float literals (except 0.0/0.5/1.0/2.0) — checked PER TOKEN, so an allowed `0.0` on the same
#     line doesn't mask a `3.7`,
#   * decimal integers >= 100 (hex/binary excluded; digit-group underscores normalised so `100_000`
#     is still seen),
#   * absolute `/Users/`, `/home/`, `/tmp/` paths — checked with string literals INTACT (that's
#     where paths live),
#   * bare project env-var name literals, when GUARDRAILS_ENV_PREFIXES is set (colon-separated,
#     e.g. "MYAPP_:OTHER_") — write the shared const, not the string.
# Exempt when the line:
#   - is inside a `const_tunable!(...)` / `config!(...)` invocation (the sanctioned home), or
#   - carries `guardrails-ok` / `hardcode-ok`, or sits inside a
#     `guardrails-ok-begin` … `guardrails-ok-end` block (hardcode-ok-begin/-end work too), or
#   - sits in a `#[cfg(test)]` module, or
#   - the file/prefix is listed in `guardrails-allow.txt`.
set -uo pipefail
root="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$root" || exit 2
allow="guardrails-allow.txt"

files=()
if [ "$#" -gt 0 ]; then for a in "$@"; do files+=("$a"); done
else while IFS= read -r x; do files+=("$x"); done < <(find crates -type f -name '*.rs' -path '*/src/*' 2>/dev/null); fi

prefixes=()
[ -f "$allow" ] && while IFS= read -r l; do l="${l%%#*}"; l="$(printf '%s' "$l" | tr -d '[:space:]')"; [ -n "$l" ] && prefixes+=("$l"); done < "$allow"

is_exempt() {
  case "$1" in *.rs) ;; *) return 0 ;; esac
  case "$1" in */src/*) ;; *) return 0 ;; esac
  # NB: guard the empty expansion — `"${prefixes[@]:-}"` yields ONE EMPTY WORD when the array is
  # empty, and an empty prefix `case`-matches every path: without this guard the gate silently
  # exempted ALL files whenever guardrails-allow.txt was absent (a vacuously-green gate).
  for p in "${prefixes[@]:-}"; do
    [ -n "$p" ] || continue
    case "$1" in "$p"*) return 0 ;; esac
  done
  return 1
}

# Colon-separated env-name prefixes to flag as bare string literals (project env vars belong in
# one shared const). Converted to an ERE alternation for awk; empty = check disabled.
env_re=""
if [ -n "${GUARDRAILS_ENV_PREFIXES:-}" ]; then
  env_re="$(printf '%s' "$GUARDRAILS_ENV_PREFIXES" | tr -s ':' '|' | sed 's/^|//; s/|$//')"
fi

hits=0
for f in "${files[@]:-}"; do
  [ -f "$f" ] || continue
  is_exempt "$f" && continue
  out="$(awk -v env_re="$env_re" '
    /#\[cfg\(test\)\]/ { intest = 1 } intest { next }
    /guardrails-ok-begin|hardcode-ok-begin/ { inblock = 1; next }   # block escape: exempt until -end
    /guardrails-ok-end|hardcode-ok-end/     { inblock = 0; next }
    inblock { next }
    /const_tunable!|config!|guardrails-ok|hardcode-ok/ { next }
    {
      line = $0
      sub(/\/\/.*/, "", line)            # strip // line comments
      # Path/env-name checks run with STRING LITERALS INTACT — that is where these values live.
      if (line ~ /\/Users\/|\/home\/|\/tmp\//) { print FILENAME ":" FNR ": " $0; next }
      if (env_re != "" && line ~ ("\"(" env_re ")")) { print FILENAME ":" FNR ": " $0; next }
      # Numeric checks run on a string-blanked copy (format specs / escape sequences are not values).
      nostr = line
      gsub(/"[^"]*"/, "", nostr)
      # Normalise digit-group underscores so 100_000 is still a 6-digit integer to the checks below.
      while (nostr ~ /[0-9]_[0-9]/) { gsub(/_/, "", nostr) }
      # Floats: PER TOKEN, so an allowed 0.0 on the line does not mask a flagged 3.7.
      s = nostr
      flagged = 0
      while (match(s, /[0-9]+\.[0-9]+/)) {
        tok = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        if (tok != "0.0" && tok != "0.5" && tok != "1.0" && tok != "2.0") { flagged = 1; break }
      }
      if (flagged) { print FILENAME ":" FNR ": " $0; next }
      # Integers >= 100 (drop hex/binary and floats from the copy first).
      t = nostr
      gsub(/0[xX][0-9a-fA-F]+/, "", t)
      gsub(/0[bB][01]+/, "", t)
      gsub(/[0-9]+\.[0-9]+/, "", t)
      if (t ~ /(^|[^0-9a-zA-Z_.])[1-9][0-9][0-9]/) { print FILENAME ":" FNR ": " $0 }
    }
  ' "$f")"
  if [ -n "$out" ]; then printf '%s\n' "$out"; hits=$((hits + $(printf '%s\n' "$out" | grep -c .))); fi
done
if [ "$hits" -gt 0 ]; then
  echo "guardrails/no-hardcoded: $hits bare value(s) — wrap in const_tunable!/config! (→ TUNABLES.md), or annotate 'guardrails-ok'." >&2
  exit 1
fi
