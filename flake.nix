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
            base="$(basename "$f" .sh)"
            case "$base" in test-*) continue ;; esac  # test harnesses aren't gates
            install -m755 "$f" "$out/bin/guardrails-$base"
          done
          # The scripts ship `#!/usr/bin/env bash`; resolve it to a concrete store
          # path so they run inside the Nix build sandbox (which has no /usr/bin/env)
          # — that's what the `checks.gates` selfcheck executes on Linux CI.
          patchShebangs $out/bin
        '';

        # `guardrails` consumer command — `guardrails info` is the terminal answer to
        # "what is this and what do I do?" (gates, escapes, and the config knobs).
        cli = pkgs.runCommand "guardrails-cli" { } ''
          mkdir -p $out/bin
          install -m755 ${./tools/guardrails.sh} $out/bin/guardrails
          install -m755 ${./tools/freshness.sh} $out/bin/guardrails-freshness
          install -m755 ${./tools/freshness-refresh.sh} $out/bin/guardrails-freshness-refresh
          install -m755 ${./tools/freshness-nudge.sh} $out/bin/guardrails-freshness-nudge
          patchShebangs $out/bin   # see gates above — sandbox has no /usr/bin/env
        '';

        # The shared toolbelt every consuming repo gets (build-time, zero runtime cost in the product).
        toolbelt = with pkgs; [
          gates
          cli             # `guardrails info` — purpose, gates, config knobs, escapes
          prek            # fast pre-commit runner (the gate/nudge engine)
          gitleaks        # secrets
          cargo-deny      # dep licenses + RUSTSEC advisories
          cargo-machete   # unused deps
          cargo-mutants   # mutation testing (test-quality signal, CI-deep)
          cargo-bloat     # binary-size attribution (lean-endproduct)
          cargo-criterion # statistical microbenchmarks (machine-readable runner)
          sccache         # shared compile cache — worktrees/repos inherit builds
          tokei           # quick LoC/scope overview
          python3         # drives the perf-budget gate (tomllib + json, no deps)
        ];
      in
      {
        # Consumers: `guardrails.lib.${system}.mkDevShell { inherit pkgs; extra = [ ... ]; }`
        #   extra : packages to add alongside the toolbelt (your toolchain).
        #   hook  : shell script appended after the guardrails banner (your cheatsheet/exports).
        #   env   : extra mkShell attrs — surfaced as environment variables in the dev shell
        #           (e.g. { PLAYWRIGHT_BROWSERS_PATH = "..."; }). Without this a consumer
        #           migrating an existing mkShell would have to `.overrideAttrs` them back on.
        #   name  : the dev-shell derivation name (defaults to mkShell's "nix-shell").
        lib = {
          inherit gates toolbelt;
          mkDevShell = { pkgs, extra ? [ ], hook ? "", env ? { }, name ? "nix-shell" }:
            pkgs.mkShell ({
              inherit name;
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
                  # Wire BOTH stages: pre-commit (fast content gates) and pre-push (slower gates
                  # the local machine runs as CI — e.g. the test suite). prek installs a pre-push
                  # shim even when the config has no pre-push hooks yet, so the day a repo adds one
                  # it's already active — no manual `prek install -t pre-push`. The bootstrap is
                  # stage-agnostic: it only re-enters the devShell to put the toolbelt on PATH, and
                  # preserves the hook's args + stdin via exec (pre-push needs its ref list on stdin).
                  if [ -n "$hd" ]; then
                    for stage in pre-commit pre-push; do
                      f="$hd/$stage"
                      # Set up ONCE per stage. If our bootstrap is already injected, leave the hook
                      # alone: prek's shim reads the live config at run time so it never needs
                      # reinstalling, and re-running `prek install` over our injected hook would
                      # migrate it to .legacy (double-run + a dangling reference). Idempotent + quiet.
                      if ! grep -qs bootstrap-pre-commit "$f"; then
                        prek install -t "$stage" >/dev/null 2>&1 || true
                        if [ -f "$f" ] && ! grep -qs bootstrap-pre-commit "$f"; then
                          # inject the bootstrap as a sourced line right after prek's shebang
                          { head -1 "$f"; echo ". ${./hooks/bootstrap-pre-commit.sh}"; tail -n +2 "$f"; } > "$f.tmp" \
                            && mv "$f.tmp" "$f" && chmod +x "$f"
                        fi
                        guardrails_installed_now=1
                      fi
                      # pre-push only: a once/week freshness nudge. prek's hook ends in `exec`, so
                      # anything appended never runs — inject it as line 3 (after shebang + the
                      # bootstrap, so the toolbelt is on PATH), before that exec. It reads only the
                      # cache, never stdin (pre-push's ref list must reach prek), and always exits 0.
                      if [ "$stage" = pre-push ] && [ -f "$f" ] && ! grep -qs guardrails-freshness-nudge "$f"; then
                        { head -2 "$f"; echo "command -v guardrails-freshness-nudge >/dev/null 2>&1 && guardrails-freshness-nudge || true"; tail -n +3 "$f"; } > "$f.tmp" \
                          && mv "$f.tmp" "$f" && chmod +x "$f"
                      fi
                    done
                  fi
                fi
                # Keep the freshness cache warm OFF the hot path: throttled (≤1/day) + detached, so
                # the shell is never blocked and never hits the network inline. The pre-push nudge
                # above reads the cache this writes. (`( … & )` fully detaches from job control.)
                if command -v guardrails-freshness-refresh >/dev/null 2>&1; then
                  ( guardrails-freshness-refresh >/dev/null 2>&1 & ) 2>/dev/null || true
                fi
                # Shared compiler-level cache across every consuming repo AND
                # worktree: each keeps its own target/ (parallel builds stay
                # parallel), every rustc call hits one fleet-wide cache — so a
                # fresh worktree's first build costs ~link time, and shared
                # deps (serde & co) compile once across projects. Opt out per
                # shell with RUSTC_WRAPPER="".
                export RUSTC_WRAPPER=''${RUSTC_WRAPPER-sccache}
                export SCCACHE_CACHE_SIZE=''${SCCACHE_CACHE_SIZE:-30G}
                if [ -n "''${guardrails_installed_now:-}" ]; then
                  echo "[guardrails] commit + push hooks installed — commits and pushes are now gated on this repo."
                else
                  echo "[guardrails] gates active on this repo."
                fi
                echo "[guardrails] escape a line with 'guardrails-ok' · run 'guardrails info' for gates + config."
                ${hook}
              '';
            } // env);
        };

        packages.gates = gates;
        packages.default = gates;

        # rustc+cargo so guardrails' own crate (tunables) builds/tests here; consumers bring their own.
        devShells.default = pkgs.mkShell { packages = toolbelt ++ [ pkgs.rustc pkgs.cargo ]; };

        # `nix flake check` runs the gates over this repo as a smoke test.
        checks.gates = pkgs.runCommand "guardrails-selfcheck" { buildInputs = [ gates ]; } ''
          cd ${./.}
          guardrails-no-fake-impl . && guardrails-no-debug-leftovers . \
            && guardrails-no-commented-code . && guardrails-no-hardcoded . && guardrails-no-conflict-markers . \
            && guardrails-derived-docs . \
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
