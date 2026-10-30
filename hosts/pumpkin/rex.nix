{ inputs, user, ... }:
{
  imports = [ inputs.rex.nixosModules.default ];

  services.rex.loginServer = {
    enable = true;
    pam = true;
    allowAnonymous = false;
    accounts.${user.username}.principals = [ "tailscale:${user.email}" ];
    defaults."tailscale:${user.email}" = user.username;
    extraListen = [ "tailnet://:7297" ];
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 7297 ];
}
