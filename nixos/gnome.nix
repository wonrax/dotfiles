{
  config,
  lib,
  pkgs,
  ...
}:
lib.mkIf config.services.desktopManager.gnome.enable {
  environment.systemPackages =
    (with pkgs; [
      gnome-tweaks
    ])
    ++ (with pkgs.gnomeExtensions; [
      tray-icons-reloaded
      user-themes
      dash-to-dock
      caffeine
    ]);
}
