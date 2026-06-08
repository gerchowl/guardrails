# guardrails-bootstrap — sourced from prek's pre-commit hook. The gate binaries
# (guardrails-*) live in the Nix devShell; merges, worktrees, and plain shells
# often commit without it active. If the gates aren't on PATH, re-enter the
# devShell (direnv keeps it cached; `nix develop` is the fallback) and re-run.
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
