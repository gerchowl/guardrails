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
# GUARDRAILS_DUP_ENFORCE=1 (pair with a ratcheted baseline, like no-hardcoded).
#
# Precision-first: an EXACT ≥K normalized-line match is a real (type-1/2) clone,
# so noise stays near zero. Diverged (type-4 "same intent, different code")
# clones are out of scope for v1 — that needs fuzzy token/embedding similarity,
# whose noise floor is too high to nudge on without triage. See CONVENTIONS.md.
#
# Knobs:
#   GUARDRAILS_DUP_ENFORCE=1        promote from nudge to hard gate (exit 1)
#   GUARDRAILS_DUP_MIN_LINES=N      window size in significant lines (default 6)
#   GUARDRAILS_DUP_EXTS="rs go ..." file extensions to scan (default below)
#   GUARDRAILS_DUP_ALLOW="glob:..." bulk-exclude path globs (space/colon-sep)
#   per-file escape: a `guardrails-ok` line anywhere in the file (drops it from
#   the corpus, so its repetition is blessed).
set -uo pipefail
roots=("${@:-.}")
enforce="${GUARDRAILS_DUP_ENFORCE:-}"
allow="${GUARDRAILS_DUP_ALLOW:-}"
min_lines="${GUARDRAILS_DUP_MIN_LINES:-6}"
exts="${GUARDRAILS_DUP_EXTS:-rs go py ts tsx js jsx c h cc cpp hpp java rb sh nix}"

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

[ "${#list[@]}" -gt 1 ] || exit 0   # need ≥2 files for a cross-site clone

report="$(GUARDRAILS_DUP_MIN_LINES="$min_lines" python3 - "${list[@]}" <<'PY'
import hashlib, os, sys

K = max(1, int(os.environ.get("GUARDRAILS_DUP_MIN_LINES", "6")))
paths = sorted(set(sys.argv[1:]))


def norm(line):
    # Drop trailing line comments (rough, language-agnostic) and collapse ws.
    for marker in ("//", "#"):
        i = line.find(marker)
        if i != -1:
            line = line[:i]
    return " ".join(line.split())


def significant(nl):
    # Skip structural/punctuation-only lines (`}`, `);`, `else {` is kept — it
    # carries a keyword). Threshold on alnum content keeps windows meaningful.
    core = "".join(ch for ch in nl if ch.isalnum() or ch == "_")
    return len(core) >= 3


# Per file: significant (orig_lineno, normalized_text).
sig = {}
for f in paths:
    try:
        with open(f, "r", errors="replace") as fh:
            rows = [
                (ln, nl)
                for ln, raw in enumerate(fh, 1)
                if significant(nl := norm(raw))
            ]
    except OSError:
        continue
    if rows:
        sig[f] = rows

# Window (K consecutive significant lines) -> occurrences (file, sig-index).
occ = {}
for f in sorted(sig):
    rows = sig[f]
    for i in range(len(rows) - K + 1):
        text = "\n".join(rows[j][1] for j in range(i, i + K))
        h = hashlib.sha1(text.encode("utf-8", "replace")).hexdigest()
        occ.setdefault(h, []).append((f, i))

dup = {h: os_ for h, os_ in occ.items() if len(os_) >= 2}

# Mark participating significant indices; remember which hashes cover each.
cover = {}
for h, occs in dup.items():
    for (f, i) in occs:
        for j in range(i, i + K):
            cover.setdefault((f, j), set()).add(h)

# Maximal contiguous duplicated regions per file (collapses the overlapping
# windows of one long clone into a single region → one report line, not many).
regions = []
by_file = {}
for (f, j) in cover:
    by_file.setdefault(f, set()).add(j)
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


# Union-find regions that share any window hash → one clone group.
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
    if len(sites) < 2:  # a lone region is not a cross-site clone
        continue
    span = max(e - s + 1 for _, s, e in sites)
    labels = [f"{f}:{sig[f][s][0]}-{sig[f][e][0]}" for (f, s, e) in sites]
    out.append((span, tuple(labels)))

for span, labels in sorted(out, key=lambda t: (-t[0], t[1])):
    print(f"  dup: ~{span} significant lines cloned across {len(labels)} sites: "
          + ", ".join(labels))
PY
)"

hits="$(printf '%s\n' "$report" | grep -c '^  dup: ' || true)"
[ "$hits" -gt 0 ] || exit 0

printf '%s\n' "$report"
msg="guardrails/duplication: $hits cloned block group(s) (≥${min_lines} normalized lines). Extract a shared helper, or bless intentional repetition with a \`guardrails-ok\` line / GUARDRAILS_DUP_ALLOW glob."
if [ -n "$enforce" ]; then
  echo "$msg" >&2
  exit 1
fi
echo "nudge: $msg" >&2
exit 0
