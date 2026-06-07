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
                # Wire the git hooks if a config is present (prek is pre-commit-config compatible).
                if [ -f .pre-commit-config.yaml ] && [ -d .git ]; then prek install >/dev/null 2>&1 || true; fi
                echo "[guardrails] gates+toolbelt ready (prek/gitleaks/cargo-deny/-machete/-mutants/-bloat)"
                ${hook}
              '';
            };
        };

        packages.gates = gates;
        packages.default = gates;

        devShells.default = pkgs.mkShell { packages = toolbelt; };

        # `nix flake check` runs the gates over this repo as a smoke test.
        checks.gates = pkgs.runCommand "guardrails-selfcheck" { buildInputs = [ gates ]; } ''
          cd ${./.}
          guardrails-no-fake-impl . && guardrails-no-debug-leftovers . && guardrails-no-commented-code . \
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
