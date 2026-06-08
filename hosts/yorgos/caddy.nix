{ pkgs, ... }:
{
  services.caddy = {
    enable = true;
    configFile = ./Caddyfile;
    package = pkgs.caddy.withPlugins {
      plugins = [ "github.com/mholt/caddy-l4@v0.1.1" ];
      hash = "sha256-CQ4vKkQ9sE6v5C0gcyYPBnDzJiPw5z14a3lY0BLZ81A=";
    };
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
}
