{
  pkgs,
  home-manager,
  user,
  unstablePkgs,
  inputs,
  ...
}:
let
  starship-daemon = import ./home/starship/daemon.nix { inherit pkgs; };

  fetch-starship-prompt-info = pkgs.writeShellScriptBin "fetch-starship-prompt-info" ''
    ${pkgs.nushell}/bin/nu ${./home/starship/fetch-starship-prompt-info.nu}
  '';

  # Shared log file for starship prompt daemons
  starshipLogPath = "/tmp/starship-prompt.log";

  # Log files to rotate and their max line counts
  logsToRotate = {
    "${starshipLogPath}" = 1000;
  };

  rotateLog = pkgs.writeScript "rotate-logs.nu" ''
    #!${pkgs.nushell}/bin/nu

    let logs = '${builtins.toJSON logsToRotate}' | from json

    $logs | transpose path lines | each {|row|
      if ($row.path | path exists) {
        ${pkgs.coreutils}/bin/tail -n $row.lines $row.path | save -f $"($row.path).tmp"
        mv $"($row.path).tmp" $row.path
      }
    }
  '';
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

  environment.systemPackages = with pkgs; [
    google-chrome
    discord
    telegram-desktop
  ];

  # Starship prompt daemon (session tracking & media info)
  launchd.user.agents.starship-daemon = {
    serviceConfig = {
      ProgramArguments = [ "${starship-daemon}/bin/starship-daemon" ];
      KeepAlive = true;
      RunAtLoad = true;
      StandardOutPath = starshipLogPath;
      StandardErrorPath = starshipLogPath;
      EnvironmentVariables = {
        # Ensure logs are written immediately
        NSUnbufferedIO = "YES";
      };
    };
  };

  # Fetch starship prompt info (PR reviews, weather, etc.) every 5 minutes
  launchd.user.agents.fetch-starship-prompt-info = {
    serviceConfig = {
      ProgramArguments = [ "${fetch-starship-prompt-info}/bin/fetch-starship-prompt-info" ];
      StartInterval = 1800; # 30 minutes
      RunAtLoad = true;
      StandardOutPath = starshipLogPath;
      StandardErrorPath = starshipLogPath;
      EnvironmentVariables = {
        # Ensure gh CLI can find its config
        HOME = "/Users/${user.username}";
        PATH = "/etc/profiles/per-user/${user.username}/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin";
        # ensure logs are written immediately without having to fflush in code
        NSUnbufferedIO = "YES";
      };
    };
  };

  # Rotate log files daily at midnight
  launchd.user.agents.rotate-logs = {
    serviceConfig = {
      ProgramArguments = [ "${rotateLog}" ];
      StartCalendarInterval = [
        {
          Hour = 0;
          Minute = 0;
        }
      ];
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
