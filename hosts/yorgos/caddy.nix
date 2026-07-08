{ pkgs, ... }:
{
  services.caddy = {
    enable = true;
    configFile = ./Caddyfile;
    package = pkgs.caddy.withPlugins {
      plugins = [ "github.com/mholt/caddy-l4@v0.1.1" ];
      hash = "sha256-EkX1kvwiwfvvdasSJyTdi1SNVHoM9Q9Y/UTX5gwiOQ4=";
    };
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
}
