{ pkgs, ... }:
{
  services.caddy = {
    enable = true;
    configFile = ./Caddyfile;
    package = pkgs.caddy.withPlugins {
      plugins = [ "github.com/mholt/caddy-l4@v0.1.1" ];
      hash = "sha256-Xo2WhsctWfrJ7sJDStd4f+4CKIibQ/CbEIY7cDsjvf0=";
    };
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
}
