#!/usr/bin/env bash
# guardrails: no debug-print leftovers — force the logging/tracing facade, not stdout spew.
# Flags dbg!()/print!()/println!()/eprint!()/eprintln!() (Rust) and console.log/debug + print(
# (TS/JS/Py) in lib/app code. Always allowed in main/bin/tests/examples, and on any line
# annotated `guardrails-ok`.
#
# CLI tools legitimately write to stdout/stderr. Set GUARDRAILS_OUTPUT_GLOBS to a colon-separated
# list of path globs for those output surfaces (e.g. "*/cli/*:*/cli.rs:*/update.rs") so the gate
# stays high-signal on app/library code instead of drowning in command-output false positives.
set -uo pipefail
roots=("${@:-.}")
hits=0

IFS=: read -ra output_globs <<< "${GUARDRAILS_OUTPUT_GLOBS:-}"

# A path is an allowed output surface if it's a built-in entrypoint/test path, or matches one of
# the repo-configured GUARDRAILS_OUTPUT_GLOBS.
allowed_output() {
  case "$1" in *gates/*|*/tests/*|*_test.*|*.test.*|*/examples/*|*/main.rs|*/bin/*) return 0 ;; esac
  local g
  for g in "${output_globs[@]}"; do
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

while IFS= read -r f; do
  case "$f" in *.rs|*.ts|*.tsx|*.js|*.mjs|*.py) ;; *) continue ;; esac
  allowed_output "$f" && continue
  pat='dbg!\(|console\.(log|debug)\(|[[:space:]]print\('
  case "$f" in *.rs) pat='dbg!\(|e?println!\(|e?print!\(' ;; esac
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
