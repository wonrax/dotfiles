{ pkgs, ... }:
{
  services.caddy = {
    enable = true;
    configFile = ./Caddyfile;
    package = pkgs.caddy.withPlugins {
      plugins = [ "github.com/mholt/caddy-l4@v0.1.0" ];
      hash = "sha256-/mxKD8218/cNlqfdrOuGCXsikqHN+FZIwB1rNinMIn0=";
    };
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
}
