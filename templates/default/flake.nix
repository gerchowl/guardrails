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
        # auto-installs the pre-commit hooks. Add your own tools via `extra`.
        devShells.default = guardrails.lib.${system}.mkDevShell {
          inherit pkgs;
          extra = [ /* pkgs.your-toolchain… */ ];
        };
      });
}
