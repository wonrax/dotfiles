{ pkgs, ... }:
{
  services.caddy = {
    enable = true;
    configFile = ./Caddyfile;
    package = pkgs.caddy.withPlugins {
      plugins = [ "github.com/mholt/caddy-l4@v0.1.1" ];
      hash = "sha256-iidNF6WoA1kzXJqT9bXB7Gmq2T9Ebhr+ZFrf7mnmnhA=";
    };
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
}
