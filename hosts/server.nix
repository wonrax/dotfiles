{
  config,
  lib,
  user,
  pkgs,
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

    vector = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable the Vector log and metrics collector service.
        '';
      };
      environmentFiles = mkOption {
        type = types.listOf types.path;
        default = [ ];
        description = ''
          List of environment files to load for the Vector service. This can be
          used to provide secrets or configuration options via environment
          variables.
        '';
      };
    };
  };

  config = {
    assertions = [
      {
        assertion = cfg.vector.environmentFiles != [ ];
        message = lib.concatStrings [
          "Set services.vector.environmentFiles when services.vector.enable = true. "
          "A license key is required."
        ];
      }
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

    boot.loader.grub.configurationLimit = 16;

    time.timeZone = "Asia/Ho_Chi_Minh";

    swapDevices = [
      {
        device = "/swapfile";
        size = cfg.swapSize;
      }
    ];

    environment.systemPackages =
      with pkgs;
      map lib.lowPrio [
        curl
        git
        neovim
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
        "--advertise-exit-node"
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

    virtualisation.podman = {
      autoPrune.enable = true;
      dockerCompat = true;
    };

    systemd.services.podman-auto-update = {
      enable = config.virtualisation.podman.enable;
      wantedBy = [ "multi-user.target" ];
    };

    systemd.timers.podman-auto-update = {
      enable = config.virtualisation.podman.enable;
      description = "Periodic Podman container auto-update";
      timerConfig = {
        OnCalendar = "hourly";
        Persistent = true;
      };
    };

    systemd.services.vector = {
      enable = cfg.vector.enable;
      description = "Vector event and log aggregator";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      requires = [ "network-online.target" ];
      serviceConfig =
        let
          vectorSettings = {
            sources = {
              journald.type = "journald";
              vector_metrics.type = "internal_metrics";
              host_metrics.type = "host_metrics";
            };

            sinks = {
              newrelic_metrics = {
                type = "new_relic";
                inputs = [
                  "vector_metrics"
                  "host_metrics"
                ];
                account_id = "4240358";
                api = "metrics";
                license_key = "$NRIA_LICENSE_KEY";
                region = "eu";
              };
              newrelic_logs = {
                type = "new_relic";
                inputs = [ "journald" ];
                account_id = "4240358";
                api = "logs";
                license_key = "$NRIA_LICENSE_KEY";
                region = "eu";
              };
            };
          };
          format = pkgs.formats.toml { };
          conf = format.generate "vector.toml" vectorSettings;
        in
        {
          ExecStart = "${lib.getExe pkgs.vector} --config ${conf}  --graceful-shutdown-limit-secs 30";
          DynamicUser = true;
          Restart = "always";
          StateDirectory = "vector";
          ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
          AmbientCapabilities = "CAP_NET_BIND_SERVICE";
          # This group is required for accessing journald.
          SupplementaryGroups = "systemd-journal";
          EnvironmentFile = cfg.vector.environmentFiles;
        };
      unitConfig = {
        StartLimitIntervalSec = 10;
        StartLimitBurst = 5;
      };
    };
  };
}
