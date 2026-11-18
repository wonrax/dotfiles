# Tailscale runs on the Windows side, so this distro has no tailscaled of its
# own to identify callers through (what the login server on pumpkin relies on).
# Instead the Rex server joins the tailnet itself as an embedded tsnet node,
# which needs no TUN device or routes and so doesn't fight the Windows client.
#
# First start is interactive: the login URL shows up in `journalctl -u rex`.
# The node identity then lives in /var/lib/rex/tsnet/opswat-wsl.
{ inputs, user, ... }:
{
  imports = [ inputs.rex.nixosModules.default ];

  services.rex = {
    enable = true;
    user = user.username;
    group = "users";
    tailscale = {
      enable = true;
      hostname = "opswat-wsl";
    };
  };
}
