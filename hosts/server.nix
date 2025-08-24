{
  config,
  lib,
  user,
  ...
}:

let
  inherit (lib)
    mkOption
    types
    ;
  cfg = config.server;
in
{
  options.server = {
    swapSize = mkOption {
      type = types.ints.unsigned;
      default = 2 * 1024;
      example = "2048";
      description = ''
        Size of the swap file in MiB. This is used to create a swap file
        at /swapfile. If set to 0, no swap file will be created.
      '';
    };

    opnix.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable the 1Password Secrets integration via opnix. This allows you to
        use 1Password Secrets in your NixOS configuration.
      '';
    };
  };

  config = {
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

    boot.loader.grub.configurationLimit = 16;

    swapDevices = [
      {
        device = "/swapfile";
        size = cfg.swapSize;
      }
    ];

    services.onepassword-secrets = {
      enable = cfg.opnix.enable;
      tokenFile = "/etc/opnix-token";
      systemdIntegration = {
        enable = true;
        changeDetection = {
          enable = true; # Only update when content actually changes
          hashFile = "/var/lib/opnix/secret-hashes";
        };
      };
    };

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
        "podman"
      ];
    };

    nix.gc = {
      automatic = true;
      options = "--delete-older-than 30d";
    };

    virtualisation.podman.autoPrune.enable = true;
  };
}
