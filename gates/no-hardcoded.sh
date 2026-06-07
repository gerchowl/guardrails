#!/usr/bin/env bash
# guardrails: no bare hardcoded numeric values — wrap them in `const_tunable!` / `config!` so every
# magic value lands in the generated TUNABLES.md (registered + auditable from one file). This is the
# enforcement half of the decorator→registry pattern.
#
# Heuristic (low false-positive, documented): in scanned `crates/*/src/**/*.rs`, flags float literals
# (except 0.0/0.5/1.0/2.0), decimal integers >= 100 (hex/binary excluded), and absolute /Users/ paths.
# Exempt when the line:
#   - is inside a `const_tunable!(...)` / `config!(...)` invocation (the sanctioned home), or
#   - carries `guardrails-ok` / `hardcode-ok`, or
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
  for p in "${prefixes[@]:-}"; do case "$1" in "$p"*) return 0 ;; esac; done
  return 1
}

hits=0
for f in "${files[@]:-}"; do
  [ -f "$f" ] || continue
  is_exempt "$f" && continue
  out="$(awk '
    /#\[cfg\(test\)\]/ { intest = 1 } intest { next }
    /const_tunable!|config!|guardrails-ok|hardcode-ok/ { next }
    {
      line = $0
      # strip // line comments and "string literals" to cut false positives
      sub(/\/\/.*/, "", line); gsub(/"[^"]*"/, "", line)
      if (line ~ /[0-9]+\.[0-9]+/ && line !~ /(^|[^0-9.])(0\.0|0\.5|1\.0|2\.0)([^0-9]|$)/) { print FILENAME ":" FNR ": " $0; next }
      if (line ~ /(^|[^0-9a-zA-Z_])[1-9][0-9][0-9]+/ && line !~ /0x|0b/) { print FILENAME ":" FNR ": " $0; next }
      if (line ~ /\/Users\//) { print FILENAME ":" FNR ": " $0 }
    }
  ' "$f")"
  if [ -n "$out" ]; then printf '%s\n' "$out"; hits=$((hits + $(printf '%s\n' "$out" | grep -c .))); fi
done
if [ "$hits" -gt 0 ]; then
  echo "guardrails/no-hardcoded: $hits bare value(s) — wrap in const_tunable!/config! (→ TUNABLES.md), or annotate 'guardrails-ok'." >&2
  exit 1
fi
