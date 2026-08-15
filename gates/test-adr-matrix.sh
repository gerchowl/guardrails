#!/usr/bin/env bash
# Red-green tests for the adr-matrix gate. Pure bash, no deps. Run: gates/test-adr-matrix.sh
#
# NOTE ON FIXTURES: these tests create real ADR *files*, because the files are the gate's source of
# truth. The previous suite only ever wrote an index — which is why it could not express "an
# Accepted ADR exists but was never indexed", the exact case that shipped two ADR-0005s in a
# consumer repo. A gate's tests have to be able to state the failure the gate exists to catch.
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

# adr <dir> <id> <slug> <status>
adr() { printf '# ADR %s — %s\n\n- Status: %s\n- Date: 2026-01-01\n' "$2" "$3" "$4" >"$1/$2-$3.md"; }

# ---------------------------------------------------------------------------
# A. files are the source of truth
# ---------------------------------------------------------------------------
d="$tmp/a"; mkdir -p "$d/adr"
adr "$d/adr" 0001 a Accepted
adr "$d/adr" 0002 b Accepted
adr "$d/adr" 0003 c Proposed
adr "$d/adr" 0004 d Accepted
cat >"$d/adr/README.md" <<'EOF'
| [0001](0001-a.md) | first feature  | **Accepted** |
| [0002](0002-b.md) | second feature | **Accepted** |
| [0003](0003-c.md) | roadmap design | **Proposed** |
| [0004](0004-d.md) | a decision     | **Accepted** |
EOF
matrix="$d/FEATURE-MATRIX.md"

printf 'row cites ADR-0001 only\n' >"$matrix"
chk "Accepted-but-uncited (0002,0004) caught"            1 -- "$d/adr/README.md" "$matrix"
chk "exempt 0004 but 0002 still uncited → caught"        1 ADR_MATRIX_EXEMPT=0004 -- "$d/adr/README.md" "$matrix"

printf 'cites ADR-0001 ADR-0002 ADR-0004\n' >"$matrix"
chk "all Accepted cited; Proposed 0003 ignored → pass"   0 -- "$d/adr/README.md" "$matrix"

printf 'cites ADR-0001 only\n' >"$matrix"
chk "0002+0004 exempt, 0001 cited → pass"                0 ADR_MATRIX_EXEMPT="0002 0004" -- "$d/adr/README.md" "$matrix"

chk "missing ADR index is a no-op"                       0 -- "$d/nope/README.md" "$matrix"

# ---------------------------------------------------------------------------
# B. the case the old suite could not express: Accepted on disk, absent from
#    the index. The gate used to read only the index, so this passed silently.
# ---------------------------------------------------------------------------
d="$tmp/b"; mkdir -p "$d/adr"
adr "$d/adr" 0001 a Accepted
adr "$d/adr" 0002 unindexed Accepted
cat >"$d/adr/README.md" <<'EOF'
| [0001](0001-a.md) | first feature | **Accepted** |
EOF
matrix="$d/FEATURE-MATRIX.md"
printf 'cites ADR-0001 and ADR-0002\n' >"$matrix"
chk "Accepted ADR missing from the index caught"         1 -- "$d/adr/README.md" "$matrix"

# …and an index that disagrees with the file's own status is drift too.
cat >"$d/adr/README.md" <<'EOF'
| [0001](0001-a.md)         | first feature | **Accepted** |
| [0002](0002-unindexed.md) | second        | **Proposed** |
EOF
chk "index Status disagreeing with the ADR file caught"  1 -- "$d/adr/README.md" "$matrix"

cat >"$d/adr/README.md" <<'EOF'
| [0001](0001-a.md)         | first feature | **Accepted** |
| [0002](0002-unindexed.md) | second        | **Accepted** |
EOF
chk "index complete and agreeing → pass"                 0 -- "$d/adr/README.md" "$matrix"

# ---------------------------------------------------------------------------
# C. duplicate ids — every `ADR-NNNN` citation is ambiguous while both exist
# ---------------------------------------------------------------------------
d="$tmp/c"; mkdir -p "$d/adr"
adr "$d/adr" 0001 one Accepted
adr "$d/adr" 0001 other Accepted
cat >"$d/adr/README.md" <<'EOF'
| [0001](0001-one.md) | first | **Accepted** |
EOF
matrix="$d/FEATURE-MATRIX.md"
printf 'cites ADR-0001\n' >"$matrix"
chk "two files claiming the same id caught"              1 -- "$d/adr/README.md" "$matrix"

# ---------------------------------------------------------------------------
# D. legacy fallback: an index with no ADR files beside it still works
# ---------------------------------------------------------------------------
d="$tmp/d"; mkdir -p "$d/adr"
cat >"$d/adr/README.md" <<'EOF'
| [0001](0001-a.md) | first feature | **Accepted** |
| [0002](0002-b.md) | second        | **Accepted** |
EOF
matrix="$d/FEATURE-MATRIX.md"
printf 'cites ADR-0001 only\n' >"$matrix"
chk "index-only repo: uncited Accepted still caught"     1 -- "$d/adr/README.md" "$matrix"
printf 'cites ADR-0001 ADR-0002\n' >"$matrix"
chk "index-only repo: all cited → pass"                  0 -- "$d/adr/README.md" "$matrix"

# ---------------------------------------------------------------------------
# F. 3-DIGIT ADR IDS — the regression
# ---------------------------------------------------------------------------
# Both of the gate's inputs used to assume FOUR digits: the filename glob
# (`[0-9][0-9][0-9][0-9]-*.md`) and the index-fallback regex (`\[0[0-9]{3}\]`).
# On a repo numbering ADRs 001-999 the glob matched no files, the gate fell
# through to the index path, that regex matched no rows, and it printed its
# green tick having compared nothing.
#
# Measured on gerchowl/strata (84 3-digit ADRs): against its real index and a
# FEATURE-MATRIX.md whose entire content was "nothing here at all", the gate
# exited 0. The only input it rejected was a matrix file that did not exist.
#
# Every fixture in sections A-E is 4-digit, which is exactly why this survived:
# a control that shares the code's assumption cannot test that assumption.
d="$tmp/f"; mkdir -p "$d/adr"
adr "$d/adr" 001 a Accepted
adr "$d/adr" 002 b Accepted
adr "$d/adr" 003 c Proposed
cat >"$d/adr/README.md" <<'EOF'
| [001](001-a.md) | first feature  | **Accepted** |
| [002](002-b.md) | second feature | **Accepted** |
| [003](003-c.md) | roadmap design | **Proposed** |
EOF
matrix="$d/FEATURE-MATRIX.md"

printf 'nothing here at all\n' >"$matrix"
chk "3-digit: empty matrix REJECTED (the regression)"    1 -- "$d/adr/README.md" "$matrix"
printf 'cites ADR-001 only\n' >"$matrix"
chk "3-digit: uncited Accepted (002) caught"             1 -- "$d/adr/README.md" "$matrix"
printf 'cites ADR-001 and ADR-002\n' >"$matrix"
chk "3-digit: all Accepted cited → pass"                 0 -- "$d/adr/README.md" "$matrix"
chk "3-digit: exemption honoured"                        0 ADR_MATRIX_EXEMPT=002 -- "$d/adr/README.md" "$matrix"

# Proposed must still be ignored at 3 digits (not merely "everything fails now").
printf 'cites ADR-001 ADR-002\n' >"$matrix"
chk "3-digit: Proposed 003 not demanded"                 0 -- "$d/adr/README.md" "$matrix"

# ---------------------------------------------------------------------------
# G. mixed widths — neither may shadow the other
# ---------------------------------------------------------------------------
d="$tmp/g"; mkdir -p "$d/adr"
adr "$d/adr" 001 a Accepted
adr "$d/adr" 0002 b Accepted
cat >"$d/adr/README.md" <<'EOF'
| [001](001-a.md)   | three digit | **Accepted** |
| [0002](0002-b.md) | four digit  | **Accepted** |
EOF
matrix="$d/FEATURE-MATRIX.md"
printf 'cites ADR-001 only\n' >"$matrix"
chk "mixed: 4-digit gap still caught"                    1 -- "$d/adr/README.md" "$matrix"
printf 'cites ADR-0002 only\n' >"$matrix"
chk "mixed: 3-digit gap still caught"                    1 -- "$d/adr/README.md" "$matrix"
printf 'cites ADR-001 and ADR-0002\n' >"$matrix"
chk "mixed: both cited → pass"                           0 -- "$d/adr/README.md" "$matrix"

# ---------------------------------------------------------------------------
# H. STATUS SPELLINGS — bold markers must not hide the status
# ---------------------------------------------------------------------------
# status_of() required the colon ADJACENT to the word, so `**Status**: Accepted`
# parsed as NO status, which the caller reads as "not Accepted" — a silent
# under-report rather than a failure. And `**Status:** Accepted` stripped to
# `** Accepted`, leaving a LEADING SPACE after `tr -d '*'`, so the caller's
# `case ... in [Aa]ccepted*)` fell through too.
#
# Both spellings dominate real repos: 65 of gerchowl/strata's 84 ADRs use them.
# With the gate blind to them it reported 5 Accepted ADRs where there were 43.
d="$tmp/h"; mkdir -p "$d/adr"
printf '# ADR 001\n\n- Status: Accepted\n'   >"$d/adr/001-plain.md"
printf '# ADR 002\n\n**Status**: Accepted\n' >"$d/adr/002-boldword.md"
printf '# ADR 003\n\n**Status:** Accepted\n' >"$d/adr/003-boldcolon.md"
printf '# ADR 004\n\n- **Status**: Accepted\n' >"$d/adr/004-listbold.md"
printf '# ADR 005\n\n## Status: Proposed\n'  >"$d/adr/005-heading.md"
cat >"$d/adr/README.md" <<'EOF'
| [001](001-plain.md)     | a | **Accepted** |
| [002](002-boldword.md)  | b | **Accepted** |
| [003](003-boldcolon.md) | c | **Accepted** |
| [004](004-listbold.md)  | d | **Accepted** |
| [005](005-heading.md)   | e | **Proposed** |
EOF
matrix="$d/FEATURE-MATRIX.md"

printf 'cites ADR-001 only\n' >"$matrix"
chk "bold spellings still count as Accepted (002-004 caught)"  1 -- "$d/adr/README.md" "$matrix"
printf 'cites ADR-001 ADR-002 ADR-003 ADR-004\n' >"$matrix"
chk "all four spellings cited → pass"                          0 -- "$d/adr/README.md" "$matrix"
chk "heading-spelled Proposed still not demanded"              0 -- "$d/adr/README.md" "$matrix"

if [ "$fails" = 0 ]; then echo "adr-matrix: all tests pass"; else echo "adr-matrix: $fails FAILED"; exit 1; fi
