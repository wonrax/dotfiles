{
  config,
  lib,
  user,
  unstablePkgs,
  inputs,
  ...
}:
let
  enableNiriIntegration = config.wonrax.dank-material-shell.enableNiriIntegration;
in
{
  options.wonrax.dank-material-shell = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable wonrax's Dank Material Shell config.";
    };
    enableNiriIntegration = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Niri integration for Dank Material Shell.";
    };
  };

  imports = [
    inputs.dms.nixosModules.dank-material-shell
    inputs.dms.nixosModules.greeter
  ];

  config = lib.mkIf config.wonrax.dank-material-shell.enable {
    programs.dank-material-shell.greeter = {
      enable = true;
      compositor.name = lib.mkIf enableNiriIntegration "niri";
      configHome = config.home-manager.users.${user.username}.home.homeDirectory;
    };
    home-manager.users.${user.username} = {
      imports = [
        inputs.dms.homeModules.dank-material-shell
        inputs.dms.homeModules.niri
      ];
      programs.dank-material-shell = {
        enable = true;
        niri = lib.mkIf enableNiriIntegration {
          enableSpawn = false; # systemd already handles this
          includes = {
            enable = true; # Enable config includes hack. Enabled by default.
            override = false; # If disabled, DMS settings won't be prioritized over settings defined using niri-flake
            originalFileName = "hm";
            filesToInclude = [
              "alttab"
              "binds"
              "colors"
              "layout"
              "outputs"
              "wpblur"
              "cursor"
            ];

          };
        };
        dgop.package = unstablePkgs.dgop;
        systemd = {
          enable = true; # Systemd service for auto-start
          restartIfChanged = true; # Auto-restart dms.service when dank-material-shell changes
        };
        enableDynamicTheming = false;
      };

      programs.niri.settings.binds = lib.mkIf enableNiriIntegration {
        "Super+Alt+L".action.spawn = [
          "dms"
          "ipc"
          "call"
          "lock"
          "lock"
        ];
      };
    };
  };
}
