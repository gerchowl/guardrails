# guardrails-bootstrap — sourced from prek's pre-commit hook. The gate binaries
# (guardrails-*) live in the Nix devShell; merges, worktrees, and plain shells
# often commit without it active. If the gates aren't on PATH, re-enter the
# devShell (direnv keeps it cached; `nix develop` is the fallback) and re-run.
# Trace identity (issue #14): one run id per hook invocation groups the per-gate JSONL rows
# guardrails-trace writes (`guardrails last` replays them); the trigger is derived from the
# hook filename. Set before the re-exec below so both branches inherit it.
if [ -z "${GR_RUN_ID:-}" ]; then
  GR_RUN_ID="$(date +%s)-$$"
  export GR_RUN_ID
  case "${0##*/}" in
    pre-commit*) GR_TRIGGER=pre-commit ;;
    pre-push*)   GR_TRIGGER=pre-push ;;
    *)           GR_TRIGGER=manual ;;
  esac
  export GR_TRIGGER
fi
if [ -z "${GR_BOOTSTRAPPED:-}" ] && ! command -v guardrails-no-fake-impl >/dev/null 2>&1; then
  GR_BOOTSTRAPPED=1
  export GR_BOOTSTRAPPED
  gr_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  if command -v direnv >/dev/null 2>&1 && [ -f "$gr_root/.envrc" ]; then
    exec direnv exec "$gr_root" "$0" "$@"
  elif command -v nix >/dev/null 2>&1; then
    exec nix --extra-experimental-features "nix-command flakes" develop "$gr_root" --command "$0" "$@"
  fi
fi
