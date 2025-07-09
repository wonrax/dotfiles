# TODO: enable nix periodic GC
# TODO: enable swap
# TODO: reorganize modules and their dependencies so that they are easier to
# manage

{
  inputs,
  user,
  home-manager,
  unstablePkgs,
  ...
}:
[
  (
    # System config
    { pkgs, ... }:
    {
      nixpkgs.config.allowUnfree = true;

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

      # Enable docker
      virtualisation.docker.enable = true;

      users.users.${user.username} = {
        isNormalUser = true;
        description = user.fullname;
        extraGroups = [
          "networkmanager"
          "wheel"
        ];

        packages = with pkgs; [
          google-chrome
          tailscale-systray
          jetbrains.datagrip
          vscode

          lazydocker

          # NOTE: These packages are NixOS specific because on macOS I'd like
          # for these programs to be able to update itself, which is only
          # possible if you install them the "normal" way.
          # - entertainment
          spotify
          plex-desktop
          # Pin VLC to 3.0.20 since 21 has an audio bug
          inputs.nixpkgs-vlc.legacyPackages.x86_64-linux.vlc
          # - communication
          discord
          telegram-desktop

          # alsamixer
          alsa-utils
        ];

        shell = pkgs.zsh;
      };

      programs._1password.enable = true;
      programs._1password-gui = {
        enable = true;
        # Certain features, including CLI integration and system authentication
        # support, require enabling PolKit integration on some desktop
        # environments (e.g. Plasma).
        polkitPolicyOwners = [ user.username ];
      };

      i18n.inputMethod = {
        enable = true;
        type = "ibus";
        ibus.engines = with pkgs.ibus-engines; [
          bamboo
        ];
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

      fonts.fontconfig.enable = true;

      programs.nh = {
        enable = true;
        flake = "/home/wonrax/.dotfiles";
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
        caffeine
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
      inherit user unstablePkgs;
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

            # TODO: also config SSH for 1password, see example in:
            # https://github.com/cbr9/dotfiles/blob/617144/modules/home-manager/ssh/default.nix
            programs.git = {
              extraConfig = {
                gpg.ssh.program = "${pkgs._1password-gui}/bin/op-ssh-sign";
              };
            };
            programs.jujutsu = {
              settings.signing.backends.ssh.program = "${pkgs._1password-gui}/bin/op-ssh-sign";
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
      users.users.${user.username}.extraGroups = [ "docker" ];

      # ==== Tailscale ====
      services.tailscale.enable = true;
      systemd.user.services.tailscale-systray = {
        enable = true;
        wantedBy = [
          "graphical-session.target"
          "multi-user.target"
        ];
        after = [ "graphical-session.target" ];
        path = with pkgs; [
          tailscale
          xdg-utils
          xclip
        ];
        serviceConfig = {
          ExecStart = pkgs.lib.getExe pkgs.tailscale-systray;
          Restart = "on-failure";
          RestartSec = "3";
        };
      };
      # https://github.com/tailscale/tailscale/issues/4432#issuecomment-1112819111
      networking.firewall.checkReversePath = "loose";

      # ==== Ulauncher ====
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

      # Disable alsamixer's auto-mute mode so that it does not mute the
      # speakers when headphones are plugged in
      systemd.services.disable-alsamixer-auto-mute = {
        enable = true;
        wantedBy = [ "multi-user.target" ];
        path = [ pkgs.alsa-utils ];
        serviceConfig = {
          User = "root";
          Group = "root";
        };
        script = ''
          # Sometimes the cards are reordered on startup, so we need to disable
          # auto-mute mode for all cards to make sure that it is disabled
          amixer -c 0 sset "Auto-Mute Mode" Disabled || true
          amixer -c 1 sset "Auto-Mute Mode" Disabled || true
          amixer -c 2 sset "Auto-Mute Mode" Disabled || true
        '';
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
        # TODO: replace with this:
        # https://github.com/kkharji/sqlite.lua?tab=readme-ov-file#nix-home-manager
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
