{
  description = "guardrails — shareable code-quality / observability / perf governance for repos (gates + toolbelt + conventions). Consume via `inputs.guardrails`.";

  inputs = {
    nixpkgs.url = "nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # The editable gate scripts (high-signal, agent-drift-aware) packaged onto PATH as
        # `guardrails-<name>`. Off-the-shelf tools cover the rest (gitleaks, clippy, cargo-deny…).
        gates = pkgs.runCommand "guardrails-gates" { } ''
          mkdir -p $out/bin
          for f in ${./gates}/*.sh; do
            name="guardrails-$(basename "$f" .sh)"
            install -m755 "$f" "$out/bin/$name"
          done
        '';

        # The shared toolbelt every consuming repo gets (build-time, zero runtime cost in the product).
        toolbelt = with pkgs; [
          gates
          prek            # fast pre-commit runner (the gate/nudge engine)
          gitleaks        # secrets
          cargo-deny      # dep licenses + RUSTSEC advisories
          cargo-machete   # unused deps
          cargo-mutants   # mutation testing (test-quality signal, CI-deep)
          cargo-bloat     # binary-size attribution (lean-endproduct)
          tokei           # quick LoC/scope overview
        ];
      in
      {
        # Consumers: `guardrails.lib.${system}.mkDevShell { inherit pkgs; extra = [ ... ]; }`
        lib = {
          inherit gates toolbelt;
          mkDevShell = { pkgs, extra ? [ ], hook ? "" }:
            pkgs.mkShell {
              packages = toolbelt ++ extra;
              shellHook = ''
                # Wire the git hooks if a config is present (prek is pre-commit-config compatible),
                # then wrap prek's hook so it self-bootstraps THIS devShell: merges, worktrees, and
                # plain shells commit without it active, which would otherwise error on the gate
                # binaries (guardrails-*) not being on PATH and force a --no-verify.
                # `[ -d .git ]` would skip linked worktrees, where .git is a FILE pointing at
                # the gitdir — so hooks never auto-wired there and every worktree commit ran
                # without the gates. Detect the repo the worktree-safe way instead; hooks live
                # in the shared common dir (git rev-parse --git-path hooks resolves to it), so
                # installing from any worktree covers the whole repo. Idempotent via the
                # bootstrap grep below.
                if [ -f .pre-commit-config.yaml ] && git rev-parse --git-dir >/dev/null 2>&1; then
                  hd="$(git rev-parse --git-path hooks 2>/dev/null)"
                  f="$hd/pre-commit"
                  # Set up ONCE. If our bootstrap is already injected, leave the hook alone:
                  # prek's shim reads the live config at run time so it never needs reinstalling,
                  # and re-running `prek install` over our injected hook would migrate it to
                  # .legacy (double-run + a dangling reference). Idempotent + quiet.
                  if [ -n "$hd" ] && ! grep -qs bootstrap-pre-commit "$f"; then
                    prek install >/dev/null 2>&1 || true
                    if [ -f "$f" ] && ! grep -qs bootstrap-pre-commit "$f"; then
                      # inject the bootstrap as a sourced line right after prek's shebang
                      { head -1 "$f"; echo ". ${./hooks/bootstrap-pre-commit.sh}"; tail -n +2 "$f"; } > "$f.tmp" \
                        && mv "$f.tmp" "$f" && chmod +x "$f"
                    fi
                  fi
                fi
                echo "[guardrails] gates+toolbelt ready (prek/gitleaks/cargo-deny/-machete/-mutants/-bloat)"
                ${hook}
              '';
            };
        };

        packages.gates = gates;
        packages.default = gates;

        # rustc+cargo so guardrails' own crate (tunables) builds/tests here; consumers bring their own.
        devShells.default = pkgs.mkShell { packages = toolbelt ++ [ pkgs.rustc pkgs.cargo ]; };

        # `nix flake check` runs the gates over this repo as a smoke test.
        checks.gates = pkgs.runCommand "guardrails-selfcheck" { buildInputs = [ gates ]; } ''
          cd ${./.}
          guardrails-no-fake-impl . && guardrails-no-debug-leftovers . \
            && guardrails-no-commented-code . && guardrails-no-hardcoded . \
            && touch $out
        '';
      })
    // {
      # `nix flake init -t github:gerchowl/guardrails` scaffolds a consumer.
      templates.default = {
        path = ./templates/default;
        description = "A repo wired to guardrails (devShell + pre-commit gates).";
      };
    };
}
