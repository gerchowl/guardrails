#!/usr/bin/env bash
# guardrails: duplication nudge — token-window clone detector (reinvention vs reuse).
# N hand-rolled copies of the same block (modal/confirm handlers, esc-return
# boilerplate, ...) are drift no per-line gate can see: no single line is wrong,
# yet the divergence is expensive (multi-round debugging to find the one copy
# that drifted). This surfaces that class early: normalize each line (strip
# comments, collapse whitespace), slide a window of K significant lines, and flag
# any window that recurs at ≥2 sites. Extract a shared helper, or annotate.
#
# NUDGE by default (report, exit 0) — a hard gate here false-positives on
# intentional repetition and trains `--no-verify`. Promote per-repo with
# GUARDRAILS_DUP_ENFORCE=1.
#
# STALENESS ESCALATION (anti-alarm-fatigue): a flat, repeated nudge habituates —
# so instead of nagging on a timer, the loudness tracks *persistence*. A finding
# recorded in the ledger (`--record`, committed like perf-history.csv) carries a
# first-seen commit; its age is counted in COMMITS to HEAD (git as the
# deterministic clock — no wall-time, stays reproducible). A clone that survives
# GUARDRAILS_DUP_ENFORCE_AGE commits undealt-with has a decayed false-positive
# probability, so it AUTO-PROMOTES from nudge → hard block: the nudge earns the
# right to become a gate. Decorate or extract it and it drops from the ledger on
# the next `--record` (ratchet-shrink). No infinite nag: every finding resolves
# to silence or a one-time block.
#
# Precision-first: an EXACT ≥K normalized-line match is a real (type-1/2) clone,
# so noise stays near zero. Diverged (type-4 "same intent, different code")
# clones are out of scope for v1 — that needs fuzzy token/embedding similarity,
# whose noise floor is too high to nudge on without triage. See CONVENTIONS.md.
#
# Modes:
#   guardrails-duplication [paths...]            check + nudge/escalate (default)
#   guardrails-duplication --record [paths...]   reconcile the ledger to disk
# Knobs:
#   GUARDRAILS_DUP_ENFORCE=1        promote ALL hits from nudge to hard gate
#   GUARDRAILS_DUP_ENFORCE_AGE=N    auto-promote a finding once it has persisted
#                                   ≥N commits (0 = off; ledger-driven)
#   GUARDRAILS_DUP_LEDGER=path      ledger file (default .guardrails/dup-ledger.tsv)
#   GUARDRAILS_DUP_MIN_LINES=N      window size in significant lines (default 6)
#   GUARDRAILS_DUP_EXTS="rs go ..." file extensions to scan (default below)
#   GUARDRAILS_DUP_ALLOW="glob:..." bulk-exclude path globs (space/colon-sep)
#   per-file escape: a `guardrails-ok` line drops the file from the corpus.
set -uo pipefail

record=""
if [ "${1:-}" = "--record" ]; then record=1; shift; fi
roots=("${@:-.}")
enforce="${GUARDRAILS_DUP_ENFORCE:-}"
enforce_age="${GUARDRAILS_DUP_ENFORCE_AGE:-0}"
ledger="${GUARDRAILS_DUP_LEDGER:-.guardrails/dup-ledger.tsv}"
allow="${GUARDRAILS_DUP_ALLOW:-}"
min_lines="${GUARDRAILS_DUP_MIN_LINES:-6}"
exts="${GUARDRAILS_DUP_EXTS:-rs go py ts tsx js jsx c h cc cpp hpp java rb sh nix}"
TAB="$(printf '\t')"

files() {
  for p in "$@"; do
    if [ -d "$p" ]; then git -C "$p" ls-files 2>/dev/null | sed "s#^#${p%/}/#" || find "$p" -type f
    elif [ -f "$p" ]; then echo "$p"; fi
  done
}

allowed() { # path matches a GUARDRAILS_DUP_ALLOW glob?
  local f="$1" g
  for g in ${allow//:/ }; do
    # shellcheck disable=SC2254
    case "$f" in $g) return 0 ;; esac
  done
  return 1
}

ext_ok() {
  local f="$1" e
  for e in $exts; do case "$f" in *."$e") return 0 ;; esac; done
  return 1
}

# Surviving corpus: right extension, not annotated, not bulk-allowed. Exclude a
# top-level tests/ component too (mirrors the other gates' relative-path skip).
list=()
while IFS= read -r f; do
  [ -f "$f" ] || continue
  case "$f" in tests/* | */tests/*) continue ;; esac
  ext_ok "$f" || continue
  grep -q 'guardrails-ok' "$f" && continue
  allowed "$f" && continue
  list+=("$f")
done < <(files "${roots[@]}")

# Detection emits one machine record per clone group:
#   GROUP<TAB>canonical_hash<TAB>n_sites<TAB>span_lines<TAB>site1|site2|...
groups_raw=""
if [ "${#list[@]}" -gt 1 ]; then
  groups_raw="$(GUARDRAILS_DUP_MIN_LINES="$min_lines" python3 - "${list[@]}" <<'PY'
import hashlib, os, sys

K = max(1, int(os.environ.get("GUARDRAILS_DUP_MIN_LINES", "6")))
paths = sorted(set(sys.argv[1:]))


def norm(line):
    for marker in ("//", "#"):
        i = line.find(marker)
        if i != -1:
            line = line[:i]
    return " ".join(line.split())


def significant(nl):
    core = "".join(ch for ch in nl if ch.isalnum() or ch == "_")
    return len(core) >= 3


sig = {}
for f in paths:
    try:
        with open(f, "r", errors="replace") as fh:
            rows = [(ln, nl) for ln, raw in enumerate(fh, 1)
                    if significant(nl := norm(raw))]
    except OSError:
        continue
    if rows:
        sig[f] = rows

occ = {}
for f in sorted(sig):
    rows = sig[f]
    for i in range(len(rows) - K + 1):
        text = "\n".join(rows[j][1] for j in range(i, i + K))
        h = hashlib.sha1(text.encode("utf-8", "replace")).hexdigest()
        occ.setdefault(h, []).append((f, i))

dup = {h: os_ for h, os_ in occ.items() if len(os_) >= 2}

cover = {}
for h, occs in dup.items():
    for (f, i) in occs:
        for j in range(i, i + K):
            cover.setdefault((f, j), set()).add(h)

by_file = {}
for (f, j) in cover:
    by_file.setdefault(f, set()).add(j)
regions = []
for f in sorted(by_file):
    idxs = sorted(by_file[f])
    start = prev = idxs[0]
    for x in idxs[1:]:
        if x == prev + 1:
            prev = x
        else:
            regions.append((f, start, prev))
            start = prev = x
    regions.append((f, start, prev))


def region_hashes(r):
    f, s, e = r
    hs = set()
    for j in range(s, e + 1):
        hs |= cover.get((f, j), set())
    return hs


parent = list(range(len(regions)))


def find(x):
    while parent[x] != x:
        parent[x] = parent[parent[x]]
        x = parent[x]
    return x


h2r = {}
for ri, r in enumerate(regions):
    for h in region_hashes(r):
        h2r.setdefault(h, []).append(ri)
for ris in h2r.values():
    for k in range(1, len(ris)):
        a, b = find(ris[0]), find(ris[k])
        if a != b:
            parent[a] = b

groups = {}
for ri, r in enumerate(regions):
    groups.setdefault(find(ri), []).append(r)

out = []
for members in groups.values():
    sites = sorted(set(members))
    if len(sites) < 2:
        continue
    span = max(e - s + 1 for _, s, e in sites)
    labels = [f"{f}:{sig[f][s][0]}-{sig[f][e][0]}" for (f, s, e) in sites]
    hs = set()
    for r in sites:
        hs |= region_hashes(r)
    ghash = min(hs) if hs else ""
    out.append((span, ghash, len(labels), labels))

for span, ghash, nsites, labels in sorted(out, key=lambda t: (-t[0], t[1])):
    print(f"GROUP\t{ghash}\t{nsites}\t{span}\t{'|'.join(labels)}")
PY
)"
fi

# Load the ledger: canonical_hash -> first_seen_commit, prior sites.
declare -A led_first led_sites
if [ -f "$ledger" ]; then
  while IFS="$TAB" read -r h fseen s _; do
    [ -n "$h" ] || continue
    led_first["$h"]="$fseen"; led_sites["$h"]="$s"
  done < "$ledger"
fi
head_sha="$(git rev-parse HEAD 2>/dev/null || true)"

report=""; new_ledger=""; hits=0; promoted=0
while IFS="$TAB" read -r tag h nsites span labels; do
  [ "$tag" = GROUP ] || continue
  hits=$((hits + 1))
  sites_disp="${labels//|/, }"
  first="${led_first[$h]:-}"
  if [ -n "$first" ]; then
    age="$(git rev-list --count "$first..HEAD" 2>/dev/null || echo 0)"
    prev="${led_sites[$h]:-$nsites}"
    grew=""
    [ "$nsites" -gt "$prev" ] 2>/dev/null && grew=" grew ${prev}→${nsites} sites"
    if [ "$enforce_age" -gt 0 ] && [ "$age" -ge "$enforce_age" ] 2>/dev/null; then
      tier="(persisted ${age} commits${grew} → PROMOTED to block)"
      promoted=$((promoted + 1))
    elif [ -n "$grew" ]; then
      tier="(persisted ${age} commits${grew}) ⚠"
    else
      tier="(persisted ${age} commits)"
    fi
    stamp="$first"
  else
    tier="(new)"
    stamp="$head_sha"
  fi
  report+="  dup: ~${span} significant lines cloned across ${nsites} sites ${tier}: ${sites_disp}"$'\n'
  new_ledger+="${h}${TAB}${stamp}${TAB}${nsites}${TAB}${span}"$'\n'
done <<< "$groups_raw"

# --record: reconcile the ledger to disk. Persisting groups keep their first-seen
# commit; new groups are stamped at HEAD; vanished (resolved) groups are dropped
# → the ledger can only shrink unless real drift appears. Sorted = clean diff.
if [ -n "$record" ]; then
  mkdir -p "$(dirname "$ledger")"
  printf '%s' "$new_ledger" | LC_ALL=C sort > "$ledger"
  exit 0
fi

[ "$hits" -gt 0 ] || exit 0
printf '%s' "$report"
msg="guardrails/duplication: $hits cloned block group(s) (≥${min_lines} normalized lines). Extract a shared helper, or bless intentional repetition with a \`guardrails-ok\` line / GUARDRAILS_DUP_ALLOW glob."
if [ "$promoted" -gt 0 ]; then
  echo "$msg" >&2
  echo "  ↑ $promoted finding(s) auto-promoted to a hard block after persisting ≥${enforce_age} commits undealt-with." >&2
  exit 1
fi
if [ -n "$enforce" ]; then
  echo "$msg" >&2
  exit 1
fi
echo "nudge: $msg" >&2
exit 0
