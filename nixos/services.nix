{ pkgs, user, ... }:
let
  fetch-starship-prompt-info = pkgs.writeShellScriptBin "fetch-starship-prompt-info" ''
    ${pkgs.nushell}/bin/nu ${../home/starship/fetch-starship-prompt-info.nu}
  '';
in
{
  # ==== Tailscale ====
  services.tailscale.enable = true;
  systemd.user.services.tailscale-systray = {
    enable = true;
    wantedBy = [
      "graphical-session.target"
      "multi-user.target"
    ];
    after = [ "graphical-session.target" ];
    path = with pkgs; [
      tailscale
      xdg-utils
      xclip
    ];
    serviceConfig = {
      ExecStart = pkgs.lib.getExe pkgs.tailscale-systray;
      Restart = "on-failure";
      RestartSec = "3";
    };
  };
  # https://github.com/tailscale/tailscale/issues/4432#issuecomment-1112819111
  networking.firewall.checkReversePath = "loose";

  # Disable alsamixer's auto-mute mode so that it does not mute the speakers
  # when headphones are plugged in. Cards can be reordered on startup, so we
  # disable auto-mute on cards 0-2 unconditionally.
  systemd.services.disable-alsamixer-auto-mute = {
    enable = true;
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.alsa-utils ];
    serviceConfig = {
      User = "root";
      Group = "root";
    };
    script = ''
      amixer -c 0 sset "Auto-Mute Mode" Disabled || true
      amixer -c 1 sset "Auto-Mute Mode" Disabled || true
      amixer -c 2 sset "Auto-Mute Mode" Disabled || true
    '';
  };

  # Starship prompt info fetcher (PR reviews, weather, etc.)
  systemd.user.services.fetch-starship-prompt-info = {
    enable = true;
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
    enable = true;
    description = "Fetch starship prompt info every 30 minutes";
    timerConfig = {
      OnBootSec = "1m";
      OnUnitActiveSec = "30m";
      Unit = "fetch-starship-prompt-info.service";
    };
    wantedBy = [ "timers.target" ];
  };
}
