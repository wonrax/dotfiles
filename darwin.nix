{
  pkgs,
  home-manager,
  user,
  unstablePkgs,
  inputs,
  ...
}:
let
  session-uptime-daemon = pkgs.stdenv.mkDerivation {
    pname = "session-uptime-daemon";
    version = "1.0.0";
    src = ./home/starship/session-uptime-daemon.swift;
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.swift ];
    buildPhase = ''
      swiftc -O -o session-uptime-daemon $src
    '';
    installPhase = ''
      mkdir -p $out/bin
      cp session-uptime-daemon $out/bin/
    '';
  };

  fetch-starship-prompt-info = pkgs.writeShellScriptBin "fetch-starship-prompt-info" ''
    ${pkgs.nushell}/bin/nu ${./home/starship/fetch-starship-prompt-info.nu}
  '';

  # Shared log file for starship prompt daemons
  starshipLogPath = "/tmp/starship-prompt.log";
in
{
  nixpkgs.config.allowUnfree = true;
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Define this so that home-manager won't complain about null home path
  users.users.${user.username}.home = "/Users/${user.username}";

  imports = [ home-manager.darwinModules.home-manager ];
  home-manager.useUserPackages = true;
  home-manager.useGlobalPkgs = true;
  home-manager.extraSpecialArgs = {
    inherit user unstablePkgs inputs;
  };
  home-manager.users.${user.username} = {
    imports = [ ./home/desktop.nix ];

    home.sessionVariables = {
      # I don't have time for this bro, will fix later
      DYLD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath (with pkgs; [ sqlite ])}:$DYLD_LIBRARY_PATH";
    };

    # NOTE: ssh agent must be enabled and configured manually in
    # 1password on macos for now
    programs.git = {
      settings = {
        gpg.ssh.program = "/Applications/1Password.app/Contents/MacOS/op-ssh-sign";
      };
    };
    programs.jujutsu = {
      settings.signing.backends.ssh.program = "/Applications/1Password.app/Contents/MacOS/op-ssh-sign";
    };
  };

  environment.systemPackages = with pkgs; [ google-chrome ];

  # Session uptime tracking daemon (listens for screen lock/unlock events)
  launchd.user.agents.session-uptime-daemon = {
    serviceConfig = {
      ProgramArguments = [ "${session-uptime-daemon}/bin/session-uptime-daemon" ];
      KeepAlive = true;
      RunAtLoad = true;
      StandardOutPath = starshipLogPath;
      StandardErrorPath = starshipLogPath;
      EnvironmentVariables = {
        SESSION_LOCK_THRESHOLD = "1800"; # 30 minutes
      };
    };
  };

  # Fetch starship prompt info (PR reviews, weather, etc.) every 5 minutes
  launchd.user.agents.fetch-starship-prompt-info = {
    serviceConfig = {
      ProgramArguments = [ "${fetch-starship-prompt-info}/bin/fetch-starship-prompt-info" ];
      StartInterval = 300; # 5 minutes
      RunAtLoad = true;
      StandardOutPath = starshipLogPath;
      StandardErrorPath = starshipLogPath;
      EnvironmentVariables = {
        # Ensure gh CLI can find its config
        HOME = "/Users/${user.username}";
        PATH = "/etc/profiles/per-user/${user.username}/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin";
      };
    };
  };

  # Add ability to used TouchID for sudo authentication
  security.pam.services.sudo_local.touchIdAuth = true;
  system = {
    primaryUser = user.username;
    defaults = {
      NSGlobalDomain.KeyRepeat = 2;
      dock = {
        autohide = true;
        showhidden = false;
        show-recents = false;
        magnification = true;
        largesize = 64;
      };
      finder = {
        AppleShowAllExtensions = true; # show all file extensions
        FXEnableExtensionChangeWarning = false; # disable warning when changing file extension
        ShowPathbar = true;
        ShowStatusBar = true;
        QuitMenuItem = true; # enable quit menu item
      };
      CustomUserPreferences = {
        "com.apple.symbolichotkeys" = {
          # Change the "Select next source in Input menu" shortcut to
          # Option+Space and disable "Select previous source in Input menu"
          # shortcut
          "AppleSymbolicHotKeys" = {
            "60" = {
              enabled = 0;
              value = {
                parameters = [
                  32
                  49
                  262144
                ];
                type = "standard";
              };
            };
            "61" = {
              enabled = 1;
              value = {
                parameters = [
                  32
                  49
                  524288
                ];
                type = "standard";
              };
            };
          };
        };
      };
    };

    keyboard = {
      enableKeyMapping = true;
      remapCapsLockToEscape = true;
    };
  };
}
