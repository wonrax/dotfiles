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

      nix.gc = {
        automatic = true;
        options = "--delete-older-than 30d";
      };

      environment.systemPackages = with pkgs; [
        vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
        git
        xclip
        unzip
        tmux
      ];

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
      };

      programs._1password.enable = true;
      programs._1password-gui = {
        enable = true;
        # Certain features, including CLI integration and system authentication
        # support, require enabling PolKit integration on some desktop
        # environments (e.g. Plasma).
        polkitPolicyOwners = [ user.username ];
      };

      programs.steam.enable = true;

      i18n.inputMethod = {
        enable = true;
        type = "fcitx5";
        fcitx5 = {
          addons = with pkgs; [
            kdePackages.fcitx5-unikey
          ];
          waylandFrontend = true;
        };
      };

      # NixOS does not follow the XDG Base Directory Specification by default
      # Tracking issue: https://github.com/NixOS/nixpkgs/issues/224525
      environment.variables = {
        XDG_CACHE_HOME = "$HOME/.cache";
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

  # Keyboard remapping
  inputs.xremap-flake.nixosModules.default
  {
    # This configures the service to only run for a specific user
    services.xremap = {
      enable = true;
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
    home-manager.useGlobalPkgs = true;
    home-manager.extraSpecialArgs = {
      inherit user unstablePkgs inputs;
    };
    home-manager.users.${user.username} = {
      imports = [
        ./home/desktop.nix
        (
          { pkgs, ... }:
          {
            # TODO: also config SSH for 1password, see example in:
            # https://github.com/cbr9/dotfiles/blob/617144/modules/home-manager/ssh/default.nix
            programs.git = {
              settings = {
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
    let
      fetch-starship-prompt-info = pkgs.writeShellScriptBin "fetch-starship-prompt-info" ''
        ${pkgs.nushell}/bin/nu ${./home/starship/fetch-starship-prompt-info.nu}
      '';
    in
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

      # Starship prompt info fetcher (PR reviews, weather, etc.)
      systemd.user.services.fetch-starship-prompt-info = {
        enable = true;
        description = "Fetch starship prompt info";
        path = with pkgs; [ nushell ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${fetch-starship-prompt-info}/bin/fetch-starship-prompt-info";
          # Ensure gh CLI can find its config
          Environment = [
            "HOME=/home/${user.username}"
          ];
        };
        wantedBy = [ "default.target" ];
      };

      systemd.user.timers.fetch-starship-prompt-info = {
        enable = true;
        description = "Fetch starship prompt info every 30 minutes";
        timerConfig = {
          OnBootSec = "1m";
          OnUnitActiveSec = "30m";
          Unit = "fetch-starship-prompt-info.service";
        };
        wantedBy = [ "timers.target" ];
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
