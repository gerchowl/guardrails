#!/usr/bin/env bash
# guardrails: no debug-print leftovers — force the logging/tracing facade, not stdout spew.
# Flags dbg!()/console.log()/print debugging in lib/app code. Allowed in main/bin/tests/examples,
# and on any line annotated `guardrails-ok`. (Rust println!/eprintln! is allowed in main.rs/bin.)
set -uo pipefail
roots=("${@:-.}")
hits=0
files() {
  for p in "$@"; do
    if [ -d "$p" ]; then git -C "$p" ls-files 2>/dev/null | sed "s#^#${p%/}/#" || find "$p" -type f
    elif [ -f "$p" ]; then echo "$p"; fi
  done
}
while IFS= read -r f; do
  case "$f" in *.rs|*.ts|*.tsx|*.js|*.mjs|*.py) ;; *) continue ;; esac
  case "$f" in *gates/*|*/tests/*|*_test.*|*.test.*|*/examples/*|*/main.rs|*/bin/*) continue ;; esac
  pat='dbg!\(|console\.(log|debug)\(|[[:space:]]print\('
  case "$f" in *.rs) pat='dbg!\(|println!\(|eprintln!\(' ;; esac
  while IFS=: read -r no line; do
    case "$line" in *guardrails-ok*) continue ;; esac
    printf '  %s:%s:%s\n' "$f" "$no" "$(printf '%s' "$line" | sed 's/^[[:space:]]*//')"
    hits=$((hits + 1))
  done < <(grep -nE "$pat" "$f" 2>/dev/null)
done < <(files "${roots[@]}")
if [ "$hits" -gt 0 ]; then
  echo "guardrails/no-debug-leftovers: $hits debug-print(s) — use the tracing facade, or annotate 'guardrails-ok'." >&2
  exit 1
fi
