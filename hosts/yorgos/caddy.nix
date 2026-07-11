{ pkgs, ... }:
{
  services.caddy = {
    enable = true;
    configFile = ./Caddyfile;
    package = pkgs.caddy.withPlugins {
      plugins = [ "github.com/mholt/caddy-l4@v0.1.1" ];
      hash = "sha256-O6GuC2q1mA/Fa0utb2Yg7ZE73iq13oVYhJI1IVyOvog=";
    };
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
}
