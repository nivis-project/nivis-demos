# The live system: everything the boot image deliberately left out.
#
# This is the other half of the sentence the bootstrap image writes. That file
# says it carries only what cannot arrive later; this one is what arrives, and
# until it exists that claim is a promise rather than a fact.
#
# It is built on the bootstrap configuration rather than beside it, and that is
# not tidiness. `switch-to-configuration` activates a COMPLETE description of
# the machine: a unit the new generation does not declare gets stopped. A live
# system assembled independently would sooner or later forget something the
# image had, and one of those things is the agent. Stopping the agent severs
# the connection the activation itself arrived over, on a machine whose
# security group admits nothing and which therefore has no second route in.
#
# So: import the image's configuration, then add. Never restate.
{
  orchestratorPublicKey,
  streamId,
  relay,
  sshPublicKey,
  agentModule,

  # What the marker reports. A parameter rather than a literal so that proving
  # "a live change replaces nothing" is a variable change and not an edit to a
  # file that also defines the agent.
  generation ? "live-1",

  ...
}@args:
{ pkgs, lib, ... }:
{
  imports = [
    (import ./configuration.nix args)
  ];

  # The marker the bootstrap image puts at "bootstrap" so a later activation has
  # something observable to change. mkForce because the imported configuration
  # sets it at the same priority, and disagreeing silently would make the one
  # thing we measure the one thing we cannot trust.
  environment.etc."tunnel-target-generation".text = lib.mkForce "${generation}\n";

  # --- an actual workload ---------------------------------------------------
  # nginx, serving one page, on loopback.
  #
  # Chosen because it is everything the image is not: a real service with a real
  # closure, absent from the image on purpose, needing no secret and no open
  # port. It listens on 127.0.0.1 alone, so the machine's claim is untouched:
  # after this arrives, a scan of its public address still finds nothing.
  #
  # That combination is the whole demonstration. A service appeared on a machine
  # that was never replaced and was never reachable.
  services.nginx = {
    enable = true;
    virtualHosts."localhost" = {
      listen = [
        {
          addr = "127.0.0.1";
          port = 8080;
        }
      ];
      root = pkgs.writeTextDir "index.html" ''
        <!doctype html>
        <title>nivis-tunnel target</title>
        <h1>${generation}</h1>
        <p>Deployed over the tunnel. This machine has never had an open port.</p>
      '';
    };
  };

  # Still nothing. nginx binds loopback, and the firewall says so rather than
  # relying on it: NixOS port lists merge rather than override, so a service
  # that later defaults to opening its own port would do it quietly.
  networking.firewall.allowedTCPPorts = lib.mkForce [ ];

  # The tools a person wants when they are on the machine to work rather than to
  # find out why it will not boot. The image drops these deliberately; this is
  # where they belong, because arriving here costs a closure push and arriving
  # in the image costs a fleet-wide replacement.
  environment.systemPackages = with pkgs; [
    curl
    htop
    rsync
  ];
}
