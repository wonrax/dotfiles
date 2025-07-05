{ user, ... }:
{
  imports = [
    ./services.nix
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

  networking.hostName = "pumpkin";

  services.tailscale = {
    enable = true;
    authKeyFile = "/etc/tailscale/authkey";
    authKeyParameters = {
      ephemeral = false;
      preauthorized = false;
    };
    extraSetFlags = [
      "--ssh"
    ];
  };

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
