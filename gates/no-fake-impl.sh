#!/usr/bin/env bash
# guardrails: no fake/placeholder implementations shipped as "done".
# Catches the #1 agent failure mode — code that *looks* finished but is a stub.
# Escape hatch: append `guardrails-ok` on the line. Tests/examples are exempt.
set -uo pipefail
roots=("${@:-.}")
pat='todo!\(|unimplemented!\(|unreachable!\("?(not|todo|fixme)|FIXME|XXX:|placeholder|not[ _-]implemented'
hits=0
files() {
  for p in "$@"; do
    if [ -d "$p" ]; then git -C "$p" ls-files 2>/dev/null | sed "s#^#${p%/}/#" || find "$p" -type f
    elif [ -f "$p" ]; then echo "$p"; fi
  done
}
while IFS= read -r f; do
  case "$f" in *.rs|*.ts|*.tsx|*.js|*.mjs|*.py|*.go) ;; *) continue ;; esac
  case "$f" in *gates/*|*/tests/*|*_test.*|*.test.*|*/examples/*) continue ;; esac
  while IFS=: read -r no line; do
    case "$line" in *guardrails-ok*) continue ;; esac
    printf '  %s:%s:%s\n' "$f" "$no" "$(printf '%s' "$line" | sed 's/^[[:space:]]*//')"
    hits=$((hits + 1))
  done < <(grep -nEi "$pat" "$f" 2>/dev/null)
done < <(files "${roots[@]}")
if [ "$hits" -gt 0 ]; then
  echo "guardrails/no-fake-impl: $hits placeholder/fake-impl marker(s) — implement, or annotate 'guardrails-ok'." >&2
  exit 1
fi
