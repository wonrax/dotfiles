{ user, config, ... }:
{
  imports = [
    ../server.nix

    ./plex.nix
    ./qbittorrent.nix
    ./vector.nix
    ./qui.nix
  ];

  nixpkgs.config.allowUnfree = true;

  fileSystems."/home/${user.username}/hdd01" = {
    device = "/dev/disk/by-uuid/ffbfae01-03f6-4d45-a29a-63ab1e25f76a";
    fsType = "ext4";
    options = [
      "nofail"
      "x-systemd.mount-timeout=30"
    ];
  };
  fileSystems."/home/${user.username}/hdd02" = {
    device = "/dev/disk/by-uuid/951fb1dc-6f5d-4af6-a6ec-042addb70405";
    fsType = "ext4";
    options = [
      "nofail"
      # shorter timeout because this drive uses external USB enclosure with its
      # own power source, should be always available when the system is on
      "x-systemd.mount-timeout=10"
    ];
  };

  boot.kernelParams = [
    # disable UAS for the two drives above. this causes minor performance
    # degradation but at least they hopefully won't randomly disconnect anymore
    # this also fixes services starting up before the drives are mounted, thus
    # causing missing files / directories (e.g. Plex library, qBittorrent)
    # https://github.com/raspberrypi/linux/issues/3070#issuecomment-786726238
    "usb-storage.quirks=0080:a001:u,152d:0562:u"
  ];

  server.swapSize = 4 * 1024; # 4 GiB swap file
  server.opnix.enable = true;

  system.stateVersion = "25.05";
  home-manager.users.${user.username}.home.stateVersion = "25.05";

  services.openssh.enable = true;

  networking.networkmanager = {
    enable = true;
    wifi.powersave = false;
  };

  # Enable container name DNS for all Podman networks.
  # Also allow qBittorrent WebUI access from containers.
  networking.firewall.interfaces =
    let
      matchAll = if !config.networking.nftables.enable then "podman+" else "podman*";
    in
    {
      "${matchAll}" = {
        allowedUDPPorts = [ 53 ];
        allowedTCPPorts = [ 10000 ]; # qBittorrent WebUI
      };
    };

  networking.hostName = "pumpkin";
}
