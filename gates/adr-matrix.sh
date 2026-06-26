#!/usr/bin/env bash
# guardrails: every **Accepted** ADR is reflected in the project's feature/status matrix. An ADR
# records a decision; a hand-maintained FEATURE-MATRIX (or status doc) silently drifts the moment an
# ADR is accepted without a matching row — and `derived-docs` can't catch a doc that has no generator.
# This gate keys on ADR **status** (Accepted), NOT on edits, so Proposed ADRs (roadmap) and typo fixes
# never trip it; only *decided* designs are required to appear.
#
# Convention: an ADR *index* (default docs/adr/README.md) has rows like
#   | [0024](0024-....md) | description | **Accepted** |
# A 4-digit id in [NNNN] plus the word "Accepted" on the row marks a required ADR; the gate then
# requires `ADR-NNNN` to appear somewhere in the matrix (default: the repo's FEATURE-MATRIX.md).
#
# Usage: guardrails-adr-matrix [<adr-index>] [<matrix>]
#   defaults: adr-index = docs/adr/README.md (else first **/adr/README.md)
#             matrix    = first **/FEATURE-MATRIX.md
# Exempt (recorded decisions that aren't feature rows): ADR numbers in guardrails-adr-exempt.txt
#   (one per line, '#' comments allowed) and/or the $ADR_MATRIX_EXEMPT env (space-separated).
set -uo pipefail

case "${1:-}" in -h | --help) sed -n '2,/^set /p' "$0" | sed 's/^# \{0,1\}//; /^set /d'; exit 0 ;; esac

index="${1:-}"
matrix="${2:-}"
[ -n "$index" ] || index="$([ -f docs/adr/README.md ] && echo docs/adr/README.md || find . -path '*/adr/README.md' -not -path '*/.git/*' 2>/dev/null | head -1)"
[ -n "$matrix" ] || matrix="$(find . -name 'FEATURE-MATRIX.md' -not -path '*/.git/*' 2>/dev/null | head -1)"
[ -f "$index" ] || { echo "guardrails-adr-matrix: no ADR index found — nothing to check"; exit 0; }
[ -f "$matrix" ] || { echo "guardrails-adr-matrix: ADR index present but no FEATURE-MATRIX.md found" >&2; exit 1; }

exempt=" ${ADR_MATRIX_EXEMPT:-} "
[ -f guardrails-adr-exempt.txt ] && exempt="$exempt $(grep -vE '^[[:space:]]*#' guardrails-adr-exempt.txt | tr '\n' ' ') "

missing=""
while IFS= read -r line; do
  num="$(printf '%s' "$line" | grep -oE '\[0[0-9]{3}\]' | head -1 | tr -dc '0-9')" || true
  [ -n "$num" ] || continue
  printf '%s' "$line" | grep -qi 'Accepted' || continue
  case "$exempt" in *" $num "*) continue ;; esac
  grep -q "ADR-$num" "$matrix" || missing="$missing $num"
done <"$index"

if [ -n "$missing" ]; then
  echo "✗ adr-matrix: Accepted ADR(s) not cited in $(basename "$matrix"):$missing" >&2
  echo "  → add a row citing ADR-NNNN, or exempt it (guardrails-adr-exempt.txt / \$ADR_MATRIX_EXEMPT)." >&2
  exit 1
fi
echo "✓ adr-matrix: every Accepted ADR is cited in $(basename "$matrix")"
