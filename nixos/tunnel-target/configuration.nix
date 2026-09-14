# tunnel-target — a machine reachable only through nivis-tunnel.
#
# This is a BOOTSTRAP image, and its thinness is the point rather than a
# side effect. On NixOS the kernel, initrd and bootloader all live in the
# closure, so `switch-to-configuration` can replace them; the only things that
# genuinely force an image rebuild are partition layout, filesystem, boot mode,
# and the agent below. Everything else a machine could ever need arrives later
# as a pushed closure.
#
# So the rule here is subtractive: if something can be deployed, it does not
# belong in this file. What is left is the smallest system that can accept one
# push — and nothing at all that listens to the outside world.
{
  # The orchestrator's PUBLIC key. The agent talks to this peer and no other.
  #
  # Public, which is what lets a boot image carry key material while carrying no
  # secret: this file, the image built from it and the AMI registered from that
  # are all safe to publish.
  orchestratorPublicKey,

  # The rendezvous id this host announces. An identifier, never a credential:
  # anyone may claim one, and all authority comes from the handshake.
  streamId,

  # host:port of the relay to dial out to.
  relay,

  # The operator's ssh public key. ssh authenticates the session; the tunnel
  # only carries it.
  sshPublicKey,

  # The agent's NixOS module, from the nivis-tunnel flake.
  agentModule,

  ...
}:
{ modulesPath, lib, ... }:
{
  imports = [
    (modulesPath + "/virtualisation/amazon-image.nix")
    # The agent. This is the one thing in the image that cannot arrive later,
    # because without it there is no way in at all.
    agentModule
  ];

  system.stateVersion = "25.05";

  # Named after the rendezvous id, because that is the only name anyone uses to
  # reach this machine: it has no DNS record and its address is not how you get
  # in. A system called "unnamed" in the logs helps nobody.
  networking.hostName = streamId;

  services.nivis-tunnel-agent = {
    enable = true;
    inherit relay streamId orchestratorPublicKey;
  };

  # sshd listens on loopback only as far as the outside world is concerned: the
  # security group admits nothing, and the agent splices the tunnel onto this
  # port from inside the machine. Everything ssh gives us — nix-copy-closure,
  # switch-to-configuration, an interactive shell — comes along for free,
  # because a ProxyCommand is indistinguishable from a network to ssh.
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
    # The load-bearing line. It defaults to true, and NixOS firewall port lists
    # MERGE rather than override — so leaving it alone would open 22 in the host
    # firewall no matter what is declared below. The cloud security group is the
    # real gate, but a machine whose own firewall disagrees with its security
    # group is a machine nobody can reason about.
    openFirewall = false;
  };

  users.users.root.openssh.authorizedKeys.keys = [ sshPublicKey ];

  # Deliberately empty, and it means it: this machine admits nothing.
  networking.firewall.allowedTCPPorts = [ ];
  networking.firewall.allowedUDPPorts = [ ];

  # A marker the deployed generation can change, so a later activation has
  # something observable to prove it took effect.
  environment.etc."tunnel-target-generation".text = "bootstrap\n";

  # --- weight --------------------------------------------------------------
  # A first pass, not a real minimisation. What is removed here is what is
  # plainly unused; what remains is either load-bearing or not yet measured.
  #
  # The reason to care is not disk. It is that this image is the ONE thing a
  # closure push cannot replace, so every megabyte in it is a megabyte that can
  # only be changed by rebuilding the image — and an image rebuild is a
  # fleet-wide machine replacement.

  # Nothing reads documentation on a machine whose only interactive use is
  # debugging through a tunnel.
  documentation.enable = false;
  documentation.nixos.enable = false;
  documentation.man.enable = false;
  documentation.info.enable = false;

  # amazon-image turns this on by default, and it is the one package in here
  # that is funny to find: the boot image of a project built to replace SSM,
  # shipping the SSM agent.
  #
  # It could not work anyway — SSM needs an instance profile and the domain
  # deliberately creates none — so this is not a second way in that would
  # undermine what rung 0 proves. It is dead weight that says the opposite of
  # what this image is for.
  # mkForce because amazon-image sets it at the same priority.
  services.amazon-ssm-agent.enable = lib.mkForce false;

  # The single largest item in the closure, and not the manuals as first
  # assumed: /etc/nix/registry.json pins the `nixpkgs` flake to the source tree,
  # so the whole 197 MiB of it comes along. That buys `nix run nixpkgs#...`
  # working offline here, on a machine nobody works on interactively.
  nix.registry = lib.mkForce { };

  # perl, rsync and strace. Useful on a machine someone logs into to work;
  # this is not one. If a debugging session ever needs them, they arrive in
  # the pushed closure, which is the whole point of the split.
  environment.defaultPackages = [ ];

  # Deliberately NOT removed, and worth writing down so the next pass does not
  # have to rediscover it:
  #
  #   nix        the target receives closures and runs switch-to-configuration;
  #              without it there is no deploying to this machine at all
  #   grub       amazon-image boots through it
  #   nixos-rebuild-ng
  #              pulls python3, 127 MiB, and is the largest remaining item
  #              after the kernel. This machine never rebuilds itself — a
  #              closure is pushed to it and switch-to-configuration is called —
  #              so it is the obvious next cut. Left in because removing a
  #              machine's ability to rebuild itself changes what happens when a
  #              deploy goes wrong, and no target has run yet to find out.
  #   amazon-init  part of amazon-image's bootstrap. We use neither its
  #              user-data handling nor its ssh key injection — the agent and
  #              the authorized key are baked in — so it is a candidate, but
  #              removing it is a change to how the machine comes up and wants
  #              its own test rather than a guess.
}
