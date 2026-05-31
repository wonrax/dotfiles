{
  user,
  config,
  pkgs,
  lib,
  ...
}:
let
  # NetworkManager keeps reporting wlan0 as "connected" even when the Pi 4's
  # brcmfmac firmware has wedged (SDIO command timeouts, err=-110), so nothing
  # auto-recovers and the host silently falls off the network until it is
  # physically power-cycled. This watchdog probes reachability and escalates.
  wifiWatchdog = pkgs.writeShellApplication {
    name = "wifi-watchdog";
    runtimeInputs = with pkgs; [
      iproute2
      iputils
      gawk
      networkmanager
      kmod
      util-linux
      systemd
    ];
    text = ''
      state="''${STATE_DIRECTORY:?}/failures"
      gw="$(ip -4 route show default | awk '{ print $3; exit }')"

      reachable() { ping -c 2 -W 2 "$1" >/dev/null 2>&1; }

      # Healthy if the gateway OR any public anchor answers, so a router that
      # ignores ICMP or a pure upstream ISP outage never triggers recovery.
      if { [ -n "$gw" ] && reachable "$gw"; } || reachable 1.1.1.1 || reachable 8.8.8.8; then
        echo 0 >"$state"
        exit 0
      fi

      fails="$(cat "$state" 2>/dev/null || echo 0)"
      fails=$(( fails + 1 ))
      echo "$fails" >"$state"
      logger -t wifi-watchdog "network unreachable (gw=''${gw:-none}, consecutive failure #$fails)"

      # Timer fires every 2 min; escalate only after sustained failure so a
      # brief router reboot or roaming blip never reacts.
      case "$fails" in
      2)
        logger -t wifi-watchdog "step 1: reconnecting wlan0"
        nmcli device reconnect wlan0 || systemctl restart NetworkManager.service
        ;;
      4)
        logger -t wifi-watchdog "step 2: reloading brcmfmac"
        systemctl stop NetworkManager.service wpa_supplicant.service || true
        ip link set wlan0 down || true
        modprobe -r brcmfmac_wcc brcmfmac || true
        sleep 2
        modprobe brcmfmac || true
        systemctl start NetworkManager.service || true
        ;;
      6)
        logger -t wifi-watchdog "step 3: wifi unrecoverable, rebooting"
        echo 0 >"$state"
        systemctl reboot
        ;;
      esac
    '';
  };
in
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
  home-manager.useGlobalPkgs = true;

  services.openssh.enable = true;

  networking.networkmanager = {
    enable = true;
    wifi.powersave = false;
  };

  # The brcmfmac firmware logs "Firmware rejected country setting" on every
  # associate and we sit on 5 GHz DFS channels; pin the regdomain so cfg80211
  # applies VN regulatory/DFS rules instead of the conservative world default.
  hardware.wirelessRegulatoryDatabase = true;
  boot.extraModprobeConfig = ''
    options cfg80211 ieee80211_regdom=VN
  '';

  # Reboot on a full kernel hang. bcm2835_wdt caps at ~16 s, so 14 s is the
  # usable ceiling; wifi-watchdog (above) covers the softer "alive but wifi
  # wedged" case the hardware watchdog cannot detect.
  systemd.settings.Manager.RuntimeWatchdogSec = "14s";

  systemd.services.wifi-watchdog = {
    description = "Recover wifi when the network is unreachable";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe wifiWatchdog;
      StateDirectory = "wifi-watchdog";
      TimeoutStartSec = "90s";
    };
  };
  systemd.timers.wifi-watchdog = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "2min";
      AccuracySec = "20s";
    };
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
