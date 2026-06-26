#!/usr/bin/env bash
# Red-green tests for the adr-matrix gate. Pure bash, no deps. Run: gates/test-adr-matrix.sh
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
gate="$here/adr-matrix.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0

# chk <desc> <want-exit> <env...> -- <index> <matrix>
chk() {
  local desc="$1" want="$2"; shift 2
  local e=(); while [ "$1" != "--" ]; do e+=("$1"); shift; done; shift
  env "${e[@]}" "$gate" "$1" "$2" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$want" ]; then echo "ok    — $desc"; else echo "FAIL  — $desc (want $want got $got)"; fails=$((fails + 1)); fi
}

mkdir -p "$tmp/adr"
cat >"$tmp/adr/README.md" <<'EOF'
| [0001](0001-a.md) | first feature  | **Accepted** |
| [0002](0002-b.md) | second feature | **Accepted** |
| [0003](0003-c.md) | roadmap design | **Proposed** |
| [0004](0004-d.md) | a decision     | **Accepted** |
EOF
matrix="$tmp/FEATURE-MATRIX.md"

# --- red: an Accepted ADR with no matrix citation is caught -------------------
printf 'row cites ADR-0001 only\n' >"$matrix"
chk "Accepted-but-uncited (0002,0004) caught"            1 -- "$tmp/adr/README.md" "$matrix"
chk "exempt 0004 but 0002 still uncaught → caught"       1 ADR_MATRIX_EXEMPT=0004 -- "$tmp/adr/README.md" "$matrix"

# --- green: all Accepted cited (Proposed 0003 ignored) ------------------------
printf 'cites ADR-0001 ADR-0002 ADR-0004\n' >"$matrix"
chk "all Accepted cited; Proposed 0003 ignored → pass"   0 -- "$tmp/adr/README.md" "$matrix"

# --- green: exemption covers the uncited ones --------------------------------
printf 'cites ADR-0001 only\n' >"$matrix"
chk "0002+0004 exempt, 0001 cited → pass"                0 ADR_MATRIX_EXEMPT="0002 0004" -- "$tmp/adr/README.md" "$matrix"

# --- no-op: no ADR index → nothing to check (exit 0) -------------------------
chk "missing ADR index is a no-op"                       0 -- "$tmp/nope/README.md" "$matrix"

if [ "$fails" = 0 ]; then echo "adr-matrix: all tests pass"; else echo "adr-matrix: $fails FAILED"; exit 1; fi
