{ user, ... }:
{
  imports = [
    ../server.nix

    ./windmill.nix
    ./plex.nix
    ./qbittorrent.nix
    ./vector.nix
  ];

  nixpkgs.config.allowUnfree = true;

  fileSystems."/home/${user.username}/hdd01" = {
    device = "/dev/sda1";
  };

  server.swapSize = 4 * 1024; # 4 GiB swap file
  server.opnix.enable = true;

  system.stateVersion = "25.05";
  home-manager.users.${user.username}.home.stateVersion = "25.05";

  services.openssh.enable = true;

  networking.networkmanager = {
    enable = true;
    wifi.powersave = false;
  };

  networking.hostName = "pumpkin";
}
