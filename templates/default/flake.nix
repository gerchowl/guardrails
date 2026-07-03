{
  description = "a repo wired to guardrails";

  inputs = {
    nixpkgs.url = "nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
    guardrails.url = "github:gerchowl/guardrails"; # ← the shared governance flake
  };

  outputs = { self, nixpkgs, flake-utils, guardrails }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; };
      in {
        # Brings the guardrails toolbelt (prek/gitleaks/cargo-deny/-mutants/-bloat + gates) and
        # auto-installs the pre-commit hooks. Add your own tools via `extra`; project env vars via
        # `env`; a shell-entry script via `hook`; and `name` the shell. `env`/`name` mean you never
        # need `.overrideAttrs` to carry an existing mkShell's environment over.
        devShells.default = guardrails.lib.${system}.mkDevShell {
          inherit pkgs;
          # name  = "myproject-dev";
          extra = [ /* pkgs.your-toolchain… */ ];
          # env  = { SOME_VAR = "value"; };
          # hook = ''echo "myproject dev shell"'';
        };

        # CI = a shim over `nix flake check` (see docs/CONVENTIONS.md). Put the
        # reproducible checks HERE so they run identically locally and in CI —
        # the workflow (templates/default/ci.yml) only invokes `nix flake check`.
        # Starts with "the dev shell builds"; add real checks (cargo test, build,
        # frontend build, …). Host-bound jobs (e2e/platform) stay out — own workflow.
        checks.default = self.devShells.${system}.default;

        # Single-sourced gates (issue #18): the SAME gate scripts prek runs on commit run
        # here over the repo — so `nix flake check` (local or via the ci.yml shim) enforces
        # the gates too. Without this, CI enforces nothing beyond "the flake evaluates".
        checks.guardrails = pkgs.runCommand "guardrails-gates-check"
          { buildInputs = [ guardrails.packages.${system}.gates ]; } ''
            cd ${self}
            guardrails-no-fake-impl . && guardrails-no-debug-leftovers . \
              && guardrails-no-commented-code . && guardrails-no-conflict-markers . \
              && guardrails-no-raw-trace-fields . \
              && touch $out
          '';
      });
}
