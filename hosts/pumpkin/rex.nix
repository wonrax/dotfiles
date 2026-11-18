# Single-user Rex server on the host's tailscaled. With tailnetAllowIdentified
# left off, Rex only admits the Tailscale account that owns this node, so this
# relies on pumpkin staying untagged (a tagged node has no owner).
{ inputs, user, ... }:
{
  imports = [ inputs.rex.nixosModules.default ];

  services.rex = {
    enable = true;
    user = user.username;
    group = "users";
    extraListen = [ "tailnet://:7297" ];
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 7297 ];
}
