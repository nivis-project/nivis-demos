{
  description = "nivis-demos — public demo stacks for nivis, catstack layout, mixed cloud";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # nivis itself: every domain is a function of `nivis.lib`. Public, so this
    # resolves over https with no credentials — a fresh clone can run the gate.
    nivis.url = "github:nivis-project/nivis";

    # Secrets at rest: age-encrypted files + the NixOS module that decrypts them
    # at activation. See secrets/secrets.nix for the recipient rules.
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Our own provider: uploads a disk image into a Hetzner project and turns it
    # into a snapshot, so a Hetzner server boots an image this repo built.
    # Consumed as a Nix store path — no registry round-trip.
    hcloudimage = {
      url = "github:nivis-project/terraform-provider-hcloudimage";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nivis,
      agenix,
      hcloudimage,
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
        env: path: extra:
        import path (
          {
            nivis = nivis.lib;
            inherit env;
          }
          // extra
        );

      # Every domain, for every environment: nivis.<env>."<domain>".
      #
      # THIS is what `stackctl` applies, so it must carry the real image builder.
      # An earlier version omitted it "so the checks never build an image", which
      # left no path by which a real apply ever got one — the placeholder went to
      # S3 and the apply failed on a file that does not exist. The checks get a
      # separate construction below instead.
      domainsFor = env: {
        "000_backend" = mkDomain env ./stack/000_backend/domain.nix { };
        "010_dns" = mkDomain env ./stack/010_dns/domain.nix { };
        "020_vaultwarden_ec2" = mkDomain env ./stack/020_vaultwarden_ec2/domain.nix {
          mkImage = mkVaultwardenEc2Image;
        };
        "030_vaultwarden_hetzner" = mkDomain env ./stack/030_vaultwarden_hetzner/domain.nix {
          mkImage = mkVaultwardenHetznerImage;
          inherit hcloudimageBin;
        };
      };

      # The same domains as the checks see them: no image builder, so evaluating
      # them can never force a build. Nothing outside the checks uses these.
      checkDomainsFor =
        env:
        domainsFor env
        // {
          "020_vaultwarden_ec2" = mkDomain env ./stack/020_vaultwarden_ec2/domain.nix {
            mkImage = _: null;
          };
          # A null builder here is what keeps the gate free of the eval-time
          # image build that hcloudimage's required image_sha256 would force.
          "030_vaultwarden_hetzner" = mkDomain env ./stack/030_vaultwarden_hetzner/domain.nix {
            mkImage = _: null;
            inherit hcloudimageBin;
          };
        };

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Domain IRs with an empty ledger — the shape tests assert on, and what
      # `build-domains` forces. A domain is `ledger -> IR`, and phase 0 (before
      # anything is applied) is exactly the empty ledger.
      # Values for REQUIRED variables (declared with no default) so the CHECKS can
      # evaluate every domain on a fresh clone with no variable source present.
      #
      # This is checks-only, and structurally so rather than by convention: a real
      # run evaluates `nivis.<env>."<domain>"`, the bare `ledger -> IR` function
      # that the executor applies its OWN ledger to. `irsFor` below is a
      # checks-only convenience and is not on that path, so nothing here can leak
      # into an apply — an apply without `domain` still fails by name.
      #
      # `.invalid` is reserved by RFC 2606 and can never resolve, so even a
      # mistake cannot reach a real name.
      checkVars = {
        domain = "demo.invalid";
        # Not a real account: 000000000000 is never issued by AWS, so the guard
        # cannot accidentally authorise anything if this ever escaped.
        awsAccountId = "000000000000";
      };

      checkLedger = {
        outputs = { };
        vars = checkVars;
      };
      irsFor = env: builtins.mapAttrs (_: domain: domain checkLedger) (checkDomainsFor env);

      # tests/*.nix are evaluation tests: each is `{ nivis, irs, envs } -> [ { name, ok, ... } ]`.
      # They must be pure (no credentials, no network, no provider process), so
      # they run at eval time and a failure fails `nix flake check` before any
      # build. See tests/README.md.
      # Host images are built as a FUNCTION of the name they will serve.
      #
      # A flake output cannot read nivis variables, and the vars file is
      # gitignored so flake evaluation cannot see it either. Fixing the name here
      # would bake the checks' fixture (demo.invalid) into the uploaded image —
      # exactly the defect this replaced. Each domain instead calls the builder
      # with the name it derived from the resolved `domain` variable.
      mkVaultwardenEc2Host =
        { domain, awsRegion }:
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            agenix.nixosModules.default
            (import ./nixos/vaultwarden-ec2/configuration.nix {
              inherit domain awsRegion;
              ssmParameterName = "/nivis-demos/demo/vaultwarden/admin-token";
            })
          ];
        };

      mkVaultwardenEc2Image =
        {
          domain,
          awsRegion,
        }:
        (mkVaultwardenEc2Host { inherit domain awsRegion; }).config.system.build.images.amazon;

      mkVaultwardenHetznerHost =
        { domain }:
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            agenix.nixosModules.default
            (import ./nixos/vaultwarden-hetzner/configuration.nix { inherit domain; })
          ];
        };

      # raw-efi: a bootable UEFI disk image, which is what hcloudimage uploads
      # and snapshots. Same shape as the infra repo, but straight from nixpkgs.
      mkVaultwardenHetznerImage =
        { domain }: (mkVaultwardenHetznerHost { inherit domain; }).config.system.build.images.raw-efi;

      # The hcloudimage provider as a store path: nivis resolves a filesystem
      # path as the provider binary itself, so there is no registry round-trip.
      hcloudimageBin = "${hcloudimage.packages.x86_64-linux.default}/bin/terraform-provider-hcloudimage";

      # Each workload's own name under the environment's domain. Demos never
      # claim the apex — that name belongs to the operator, not to an example.
      servedName = label: domain: "${label}.${domain}";

      # Evaluated by the checks, so this one carries the fixture name. It is NOT
      # what a real apply uploads: that image comes from mkVaultwardenEc2Image,
      # built for the resolved name.
      nixosHosts = {
        vaultwarden-ec2 = mkVaultwardenEc2Host {
          domain = servedName "vault-ec2" checkVars.domain;
          awsRegion = environments.demo.vars.awsRegion.default;
        };
        vaultwarden-hetzner = mkVaultwardenHetznerHost {
          domain = servedName "vault-hetzner" checkVars.domain;
        };
      };

      evalTestFiles = [
        ./tests/000_backend.nix
        ./tests/010_dns.nix
        ./tests/account-guard.nix
        ./tests/020_vaultwarden_ec2.nix
        ./tests/030_vaultwarden_hetzner.nix
        ./tests/vaultwarden-module.nix
        ./tests/vars.nix
        ./tests/secrets.nix
      ];
      evalTestResults = builtins.concatLists (
        map (
          f:
          import f {
            nivis = nivis.lib;
            irs = irsFor environments.demo;
            # The raw `ledger -> IR` functions, so a test can evaluate a domain
            # against an injected ledger (e.g. overridden vars).
            domains = checkDomainsFor environments.demo;
            # The domain as `stackctl` actually applies it — with the real image
            # builder — so a test can prove it does not ship the placeholder.
            realDomains = domainsFor environments.demo;
            inherit checkVars;
            # A one-byte stand-in for the disk image. It exercises the real
            # code path — `drv` and the hashFile the provider forces — without
            # building a multi-GB NixOS image inside the gate.
            hetznerWithImage =
              tag:
              import ./stack/030_vaultwarden_hetzner/domain.nix {
                nivis = nivis.lib;
                env = environments.demo;
                hcloudimageBin = "/nix/store/stub/bin/terraform-provider-hcloudimage";
                mkImage =
                  _:
                  (nixpkgs.legacyPackages.x86_64-linux.runCommand "fake-disk-image-${tag}" { } ''
                    mkdir -p $out
                    echo ${tag} > $out/nixos.img
                  '').overrideAttrs
                    (o: {
                      passthru = (o.passthru or { }) // {
                        filePath = "nixos.img";
                      };
                    });
              };
            envs = environments;
            hosts = nixosHosts;
            # A domain evaluated WITH an image, so a test can prove the image
            # becomes a __build leaf. Uses a trivial derivation, not the real
            # image: the checks must never force an image build.
            withImage =
              img:
              import ./stack/020_vaultwarden_ec2/domain.nix {
                nivis = nivis.lib;
                env = environments.demo;
                mkImage =
                  {
                    domain,
                    awsRegion,
                  }:
                  img;
              };
            inherit servedName;
            secretsRules = import ./secrets/secrets.nix;
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

      nixosConfigurations = nixosHosts;

      # Exposed so the image can be built BEFORE an apply.
      #
      # nivis realises a __build leaf with `nix-store --realise <outputPath>`
      # (internal/phase/evaluator.go), which can substitute a path or use one
      # that already exists, but cannot BUILD it — that needs the .drv. A
      # locally-built image is in no cache, so the first apply fails with
      # "no substituter that can build it". Pre-building puts the path in the
      # store, after which the realise is a no-op.
      lib = {
        inherit mkVaultwardenEc2Image servedName;
      };

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            nivis.packages.${pkgs.stdenv.hostPlatform.system}.nivis
            pkgs.awscli2
            pkgs.hcloud
            pkgs.age
            pkgs.jq
            pkgs.shellcheck
            pkgs.nixfmt
            pkgs.lolcat
          ];
          shellHook = ''
            echo
            echo "   Nix Meetup 2026 Amersfoort Nivis Demo" | lolcat
            echo
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
