#!/usr/bin/env bash
# guardrails: protect-trunk-push — refuse pushes that advance a protected REMOTE ref. The
# pre-push half of protect-trunk: keyed on the remote ref from the push spec, NOT on HEAD, so
# it catches what the pre-commit gate structurally can't:
#   * `git push origin HEAD:main` from a feature branch (the exact incident refspec, issue #17)
#   * commits that never fired pre-commit: clean cherry-pick/revert, plumbing (commit-tree)
#
# git feeds pre-push one line per ref on stdin: <local-ref> <local-sha> <remote-ref> <remote-sha>
# Deletions (local-sha all-zeros) are skipped — removing a stray remote branch is not advancing
# trunk, and trunk deletion is the forge's protection to enforce.
#
# Same knobs as protect-trunk.sh: GUARDRAILS_PROTECTED_BRANCHES (colon-sep globs, REPLACES the
# `main:master` default, empty disables), GUARDRAILS_ALLOW_TRUNK=1 escape (loud), CI auto-allow.
set -uo pipefail

if [ "${GUARDRAILS_ALLOW_TRUNK:-0}" = 1 ]; then
  echo "guardrails/protect-trunk-push: GUARDRAILS_ALLOW_TRUNK=1 — intentional trunk push allowed." >&2
  exit 0
fi
case "${CI:-}" in true|1) exit 0 ;; esac
case "${GITHUB_ACTIONS:-}" in true|1) exit 0 ;; esac

IFS=: read -ra protected <<< "${GUARDRAILS_PROTECTED_BRANCHES-main:master}"

zeros=0000000000000000000000000000000000000000
fails=0
while read -r _local_ref local_sha remote_ref _remote_sha; do
  [ -n "${remote_ref:-}" ] || continue
  [ "$local_sha" = "$zeros" ] && continue # deletion, not an advance
  branch="${remote_ref#refs/heads/}"
  [ "$branch" = "$remote_ref" ] && continue # tags/notes/etc. — only heads are trunk
  set -f
  for pat in "${protected[@]}"; do
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2254  # $pat is intentionally a glob
    case "$branch" in
      $pat)
        echo "guardrails/protect-trunk-push: refusing to push to protected '$branch' — trunk advances by merge/PR only." >&2
        echo "  Push a feature branch and open a PR:  git push origin HEAD:refs/heads/<feature-name>" >&2
        echo "  Intentional (hotfix/release)?         GUARDRAILS_ALLOW_TRUNK=1 git push ..." >&2
        fails=$((fails + 1))
        ;;
    esac
  done
  set +f
done

[ "$fails" -eq 0 ] || exit 1
