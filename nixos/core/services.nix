{ pkgs, user, ... }:
let
  fetch-starship-prompt-info = pkgs.writeShellScriptBin "fetch-starship-prompt-info" ''
    ${pkgs.nushell}/bin/nu ${../../home/starship/fetch-starship-prompt-info.nu}
  '';
in
{
  # ==== Tailscale ====
  services.tailscale.enable = true;
  # https://github.com/tailscale/tailscale/issues/4432#issuecomment-1112819111
  networking.firewall.checkReversePath = "loose";

  # Starship prompt info fetcher (PR reviews, weather, etc.)
  systemd.user.services.fetch-starship-prompt-info = {
    description = "Fetch starship prompt info";
    path = with pkgs; [ nushell ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${fetch-starship-prompt-info}/bin/fetch-starship-prompt-info";
      Environment = [ "HOME=/home/${user.username}" ];
    };
    wantedBy = [ "default.target" ];
  };

  systemd.user.timers.fetch-starship-prompt-info = {
    description = "Fetch starship prompt info every 30 minutes";
    timerConfig = {
      OnBootSec = "1m";
      OnUnitActiveSec = "30m";
      Unit = "fetch-starship-prompt-info.service";
    };
    wantedBy = [ "timers.target" ];
  };
}
