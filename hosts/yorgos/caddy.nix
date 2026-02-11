{ pkgs, ... }:
{
  services.caddy = {
    enable = true;
    configFile = ./Caddyfile;
    package = pkgs.caddy.withPlugins {
      plugins = [ "github.com/mholt/caddy-l4@v0.0.0-20260216070754-eca560d759c9" ];
      hash = "sha256-HhI0s8bi+T89dz0V0yfrTU/1NTK5wJUtxxn7Sg9Fi9g=";
    };
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
}
