{ user, ... }:
{
  imports = [
    ../server.nix

    ./plex.nix
    ./qbittorrent.nix
    ./vector.nix
  ];

  nixpkgs.config.allowUnfree = true;

  fileSystems."/home/${user.username}/hdd01" = {
    device = "/dev/disk/by-uuid/ffbfae01-03f6-4d45-a29a-63ab1e25f76a";
    fsType = "ext4";
    options = [ "nofail" ];
  };
  fileSystems."/home/${user.username}/hdd02" = {
    device = "/dev/disk/by-uuid/951fb1dc-6f5d-4af6-a6ec-042addb70405";
    fsType = "ext4";
    options = [ "nofail" ];
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
