{
  description = "nivis-demos — public demo stacks for nivis, catstack layout, mixed cloud";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # nivis itself: every domain is a function of `nivis.lib`. Public, so this
    # resolves over https with no credentials — a fresh clone can run the gate.
    nivis.url = "github:nivis-project/nivis";

    # Added when the first domain that references them lands:
    #   hcloudimage.url = "github:nivis-project/terraform-provider-hcloudimage";
    #   nixos-generators.url = "github:nix-community/nixos-generators";
    #   agenix.url = "github:ryantm/agenix";
  };

  outputs =
    {
      self,
      nixpkgs,
      nivis,
    }:
    let
      # The gate `/mip:ship` enforces, and the single source of truth for it.
      # This repo's unit of work is a catstack *domain*, so coverage means
      # "share of stack/<name>/domain.nix exercised by a test under tests/".
      # See scripts/coverage-gate.sh for the mechanics.
      coverage = {
        overallMin = 70;
        coreMin = 80;
        # Load-bearing domains every demo sits on — held to the higher bar.
        # 000_backend holds every other domain's state.
        coreDomains = [ "000_backend" ];
      };

      # Environments, one attrset per file in ./environments.
      environments = {
        demo = import ./environments/demo.nix;
      };

      # A catstack domain: a file `{ nivis, env } -> ledger -> IR`, applied as
      # `nivis <verb> --attr 'nivis.<env>."<domain>"'` (see ./stackctl). Each
      # domain carries its own state key, so state is isolated per domain.
      mkDomain =
        env: path:
        import path {
          nivis = nivis.lib;
          inherit env;
        };

      # Every domain, for every environment: nivis.<env>."<domain>".
      domainsFor = env: {
        "000_backend" = mkDomain env ./stack/000_backend/domain.nix;
      };

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Domain IRs with an empty ledger — the shape tests assert on, and what
      # `build-domains` forces. A domain is `ledger -> IR`, and phase 0 (before
      # anything is applied) is exactly the empty ledger.
      emptyLedger = {
        outputs = { };
      };
      irsFor = env: builtins.mapAttrs (_: domain: domain emptyLedger) (domainsFor env);

      # tests/*.nix are evaluation tests: each is `{ nivis, irs, envs } -> [ { name, ok, ... } ]`.
      # They must be pure (no credentials, no network, no provider process), so
      # they run at eval time and a failure fails `nix flake check` before any
      # build. See tests/README.md.
      evalTestFiles = [
        ./tests/000_backend.nix
      ];
      evalTestResults = builtins.concatLists (
        map (
          f:
          import f {
            nivis = nivis.lib;
            irs = irsFor environments.demo;
            envs = environments;
          }
        ) evalTestFiles
      );
      # Force every assertion; throw on the first failure with its name.
      checkedEvalTests = map (
        r: if r.ok then r.name else throw "eval test FAILED: ${r.name}${r.detail or ""}"
      ) evalTestResults;
    in
    {
      # Catstack domains, one flake attr + one state key each.
      nivis = builtins.mapAttrs (_: env: domainsFor env) environments;

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            nivis.packages.${pkgs.system}.nivis
            pkgs.awscli2
            pkgs.hcloud
            pkgs.age
            pkgs.jq
            pkgs.shellcheck
            pkgs.nixfmt
          ];
          shellHook = ''
            echo "nivis-demos — run 'beans prime' and 'openspec context' to orient."
          '';
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);

      # `nix flake check` builds every attr below: build + tests + coverage.
      checks = forAllSystems (pkgs: {
        # --- build -------------------------------------------------------
        # Every domain must evaluate to an IR, for every environment.
        build-domains =
          let
            report = builtins.concatStringsSep "\n" (
              builtins.concatLists (
                builtins.attrValues (
                  builtins.mapAttrs (
                    envName: env:
                    builtins.attrValues (
                      builtins.mapAttrs (
                        name: ir:
                        "  ${envName}/${name}: schemaVersion=${toString ir.schemaVersion} "
                        + "resources=${toString (builtins.length ir.resources)}"
                      ) (irsFor env)
                    )
                  ) environments
                )
              )
            );
          in
          pkgs.runCommand "check-build-domains" { } ''
            cat <<'EOF'
            domains evaluated:
            ${report}
            EOF
            touch $out
          '';

        # --- tests -------------------------------------------------------
        # Two kinds: eval tests (tests/*.nix, forced above) and script tests
        # (tests/*.sh, run here in the sandbox).
        tests =
          pkgs.runCommand "check-tests"
            {
              nativeBuildInputs = [ pkgs.bash ];
              # Referencing the forced list makes a failing eval test fail this
              # derivation's *evaluation*, before anything is built.
              EVAL_TESTS = builtins.concatStringsSep "\n" checkedEvalTests;
            }
            ''
              echo "==> eval tests (${toString (builtins.length checkedEvalTests)} assertions)"
              printf '%s\n' "$EVAL_TESTS" | sed 's/^/    ok /'

              shopt -s nullglob
              for t in ${self}/tests/*.sh; do
                echo "==> $t"
                bash "$t"
              done
              touch $out
            '';

        # --- coverage ----------------------------------------------------
        coverage =
          pkgs.runCommand "check-coverage"
            {
              nativeBuildInputs = [
                pkgs.findutils
                pkgs.gnugrep
              ];
              OVERALL_MIN = toString coverage.overallMin;
              CORE_MIN = toString coverage.coreMin;
              CORE_DOMAINS = toString coverage.coreDomains;
            }
            ''
              bash ${self}/scripts/coverage-gate.sh ${self}
              touch $out
            '';

        # --- hygiene -----------------------------------------------------
        fmt = pkgs.runCommand "check-fmt" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
          nixfmt --check $(find ${self} -name '*.nix' -type f)
          touch $out
        '';

        shell = pkgs.runCommand "check-shell" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
          shellcheck ${self}/scripts/*.sh ${self}/stackctl ${self}/tests/*.sh
          touch $out
        '';
      });
    };
}
