{ pkgs, ... }:
{
  systemd.user.services.tailscale-systray = {
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

  # Disable alsamixer's auto-mute mode so that it does not mute the speakers
  # when headphones are plugged in. Cards can be reordered on startup, so we
  # disable auto-mute on cards 0-2 unconditionally.
  systemd.services.disable-alsamixer-auto-mute = {
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
}
