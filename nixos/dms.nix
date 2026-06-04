{
  config,
  lib,
  user,
  unstablePkgs,
  pkgs,
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
    # DMS's syncModeWithPortal toggle runs `gsettings set
    # org.gnome.desktop.interface color-scheme ...` via fire-and-forget
    # execDetached. Without the gsettings schemas in the session env that
    # command dies with "No schemas installed" and the portal color-scheme
    # never moves, so apps don't follow the DMS light/dark toggle. Expose the
    # schemas to the whole niri session (login shells + systemd user services
    # like dms.service) so the write actually lands.
    environment.sessionVariables.GSETTINGS_SCHEMA_DIR = "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas";

    programs.dank-material-shell.greeter = {
      enable = true;
      compositor.name = lib.mkIf enableNiriIntegration "niri";
      configHome = config.home-manager.users.${user.username}.home.homeDirectory;
    };
    users.users.${user.username}.packages = with pkgs; [
      slurp # for the screenCaptureToolbar plugin
      gpu-screen-recorder # for the screenCaptureToolbar plugin
    ];
    home-manager.users.${user.username} = {
      imports = [
        inputs.dms.homeModules.dank-material-shell
        inputs.dms.homeModules.niri
        inputs.dms-plugin-registry.modules.default
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
        plugins = {
          dockerManager.enable = true;
          screenCaptureToolbar.enable = true;
        };
      };

      programs.niri.settings.binds = lib.mkIf enableNiriIntegration {
        "Super+Alt+L".action.spawn = [
          "dms"
          "ipc"
          "call"
          "lock"
          "lock"
        ];
        "Super+Shift+S".action.spawn = [
          # dms ipc call screenCaptureToolbar open
          "dms"
          "ipc"
          "call"
          "screenCaptureToolbar"
          "open"
        ];
      };
    };
  };
}
