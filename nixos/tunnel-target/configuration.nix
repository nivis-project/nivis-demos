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
{ modulesPath, ... }:
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
}
