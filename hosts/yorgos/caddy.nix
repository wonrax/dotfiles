{ pkgs, ... }:
{
  services.caddy = {
    enable = true;
    configFile = ./Caddyfile;
    package = pkgs.caddy.withPlugins {
      plugins = [ "github.com/mholt/caddy-l4@v0.1.1" ];
      hash = "sha256-tqIbjHp3DXP8frPsQNQ2JX8p8smXK5+tbQAwfJYNcmM=";
    };
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
}
