{ user, ... }:
{
  imports = [
    ./windmill.nix
    ./plex.nix
    ./qbittorrent.nix
  ];

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];

    # Needed for remote build and deployment
    trusted-users = [
      "@wheel" # Trust all users in the wheel group, aka sudoers
    ];
  };

  nixpkgs.config.allowUnfree = true;

  fileSystems."/home/${user.username}/hdd01" = {
    device = "/dev/sda1";
  };

  swapDevices = [
    {
      device = "/swapfile";
      size = 4 * 1024; # 4GB
    }
  ];

  system.stateVersion = "25.05";

  services.openssh.enable = true;

  users.groups.${user.username} = { };
  users.users.${user.username} = {
    isNormalUser = true;
    group = user.username;
    openssh.authorizedKeys.keys = [
      user.ssh-pub-key
    ];
    extraGroups = [
      "wheel"
      "docker"
    ];
  };

  networking.networkmanager = {
    enable = true;
    wifi.powersave = false;
  };

  services.onepassword-secrets = {
    enable = true;
    tokenFile = "/etc/opnix-token";
    systemdIntegration = {
      enable = true;
      changeDetection = {
        enable = true; # Only update when content actually changes
        hashFile = "/var/lib/opnix/secret-hashes";
      };
    };
  };

  networking.hostName = "pumpkin";

  services.tailscale = {
    enable = true;
    authKeyFile = "/etc/tailscale/authkey";
    extraSetFlags = [
      "--ssh"
    ];
  };
  # Allow tailscale to figure out direct connections on hard networks
  # https://tailscale.com/kb/1082/firewall-ports#my-devices-are-using-a-relay-what-can-i-do-to-help-them-connect-peer-to-peer
  networking.firewall.allowedUDPPorts = [ 41641 ];

  security.sudo.extraRules = [
    {
      users = [ user.username ];
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
