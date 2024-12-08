# TODO: enable nix periodic GC
# TODO: enable swap

{
  inputs,
  user,
  home-manager,
  ...
}:
[
  (
    # System config
    { pkgs, ... }:
    {
      environment.systemPackages = with pkgs; [
        vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
        git
        gnome-tweaks
        xclip
        unzip
        tmux
      ];

      # Enable ZSH so that it's available on login
      programs.zsh.enable = true;

      users.users.${user.username} = {
        isNormalUser = true;
        description = user.fullname;
        extraGroups = [
          "networkmanager"
          "wheel"
        ];

        packages = with pkgs; [
          google-chrome
        ];

        shell = pkgs.zsh;
      };

      programs._1password.enable = true;
      programs._1password-gui = {
        enable = true;
        # Certain features, including CLI integration and system authentication support,
        # require enabling PolKit integration on some desktop environments (e.g. Plasma).
        # polkitPolicyOwners = [ "yourUsernameHere" ];
      };

      # NixOS does not follow the XDG Base Directory Specification by default
      # Tracking issue: https://github.com/NixOS/nixpkgs/issues/224525
      environment.variables = {
        XDG_CACHE_HOME = "$HOME/.cache";
        XDG_CONFIG_DIRS = "/etc/xdg";
        XDG_CONFIG_HOME = "$HOME/.config";
        XDG_DATA_HOME = "$HOME/.local/share";
        XDG_STATE_HOME = "$HOME/.local/state";
      };
    }
  )

  (
    # Gnome extensions
    { pkgs, ... }:
    {
      environment.systemPackages = with pkgs.gnomeExtensions; [
        tray-icons-reloaded
        user-themes
        dash-to-dock
      ];

    }
  )

  # Keyboard remapping
  inputs.xremap-flake.nixosModules.default
  {
    # This configures the service to only run for a specific user
    services.xremap = {
      /*
        NOTE: since this sample configuration does not have any DE,
        xremap needs to be started manually by systemctl --user start xremap
      */
      serviceMode = "user";
      userName = user.username;
    };
    # Modmap for single key rebinds
    services.xremap.config.modmap = [
      {
        name = "Global";
        remap = {
          "CapsLock" = "Esc";
        }; # globally remap CapsLock to Esc
      }
    ];
  }

  # make home-manager as a module of nixos
  # so that home-manager configuration will be deployed automatically when executing `nixos-rebuild switch`
  home-manager.nixosModules.home-manager
  {
    home-manager.useUserPackages = true;
    home-manager.extraSpecialArgs = {
      user = user;
    };
    home-manager.users.${user.username} = {
      imports = [
        ./home.nix
        (
          { pkgs, ... }:
          let
            rofi-launchers = pkgs.callPackage ./rofi.nix { };
          in
          {
            home.packages = with pkgs; [
              rofi
              rofi-launchers.package
            ];

            dconf.settings = {
              "org/gnome/settings-daemon/plugins/media-keys" = {
                custom-keybindings = [
                  "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/"
                ];
              };
              "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" = {
                # Super + Space
                # NOTE: if this does not work, try disabling the default
                # binding (likely input switching) in the GNOME settings and
                # then re-switch configuration
                binding = "<Super>space";
                command = pkgs.lib.getExe rofi-launchers.launch;
                name = "Launch ulauncher";
              };
            };
          }
        )
      ];
    };
  }

  (
    # Systemd services
    { pkgs, ... }:
    {
      # TODO: find a way to group all things related to a module (e.g.
      # ulauncher) into a single module and not spread them across multiple
      # modules
      systemd.user.services."net.launchpad.ulauncher" = {
        enable = false; # Disabled because we're using rofi instead
        wantedBy = [
          "graphical-session.target"
          "multi-user.target"
        ];
        after = [ "graphical-session.target" ];
        environment = {
          GDK_BACKEND = "x11";
        };
        serviceConfig = {
          Type = "dbus";
          BusName = "io.ulauncher.Ulauncher";
          # A hack to fix ulauncher unable to find the installed apps
          # https://github.com/NixOS/nixpkgs/issues/214668#issuecomment-1722569860
          ExecStart = pkgs.writeShellScript "ulauncher-env-wrapper.sh" ''
            export PATH="''${XDG_BIN_HOME}:$HOME/.nix-profile/bin:/etc/profiles/per-user/$USER/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin"
            exec ${pkgs.ulauncher}/bin/ulauncher --hide-window
          '';
          Restart = "on-failure";
          RestartSec = "1";
        };
      };
    }
  )

  (
    # Globally linked libraries using nix-ld
    { pkgs, ... }:
    {
      programs.nix-ld.enable = true;
      programs.nix-ld.libraries = with pkgs; [
        libxkbcommon

        # currently only neovim's smart open depends on this
        sqlite

        # libGL
        # wayland
      ];
      environment.variables = {
        # Register the nix-ld library path
        LD_LIBRARY_PATH = "$LD_LIBRARY_PATH:$NIX_LD_LIBRARY_PATH";
      };
    }
  )
]
