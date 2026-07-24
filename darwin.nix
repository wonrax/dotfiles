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

  boring-notch = pkgs.stdenv.mkDerivation rec {
    pname = "boringNotch";
    version = "2.7.3";

    src = pkgs.fetchurl {
      url = "https://github.com/TheBoredTeam/boring.notch/releases/download/v${version}/boringNotch.dmg";
      sha256 = "sha256-I3hjglSNM8WbMJ21WOUTqS4/lbY9YRVE3N310ZbkZpg=";
    };

    # No build inputs needed - we use macOS native hdiutil
    dontBuild = true;
    dontFixup = true;

    unpackPhase = ''
      # Mount the DMG
      mkdir -p mount
      # FIXME: impure alert!
      # build from source instead since it's open source?
      /usr/bin/hdiutil attach -nobrowse -readonly $src -mountpoint ./mount

      # Copy contents
      mkdir -p contents
      cp -r ./mount/* ./contents/ || true

      # Unmount
      /usr/bin/hdiutil detach ./mount
    '';

    sourceRoot = "contents";

    installPhase = ''
      mkdir -p $out/Applications
      cp -r *.app $out/Applications/ || cp -r boringNotch.app $out/Applications/
    '';

    meta = with pkgs.lib; {
      description = "Boring Notch - a notch replacement app for macOS";
      homepage = "https://github.com/TheBoredTeam/boring.notch";
      platforms = platforms.darwin;
    };
  };

  # Shared log file for starship prompt daemons
  starshipLogPath = "/tmp/starship-prompt.log";

  agentflow = import ./agentflow/package.nix { inherit pkgs; };
  agentflowLogPath = "/tmp/agentflow.log";

  # Log files to rotate and their max line counts
  logsToRotate = {
    "${starshipLogPath}" = 1000;
    "${agentflowLogPath}" = 5000;
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
  nix.enable = false; # determinate nix
  nixpkgs.config.allowUnfree = true;
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  # disabled because this requires nix.enabled + determinate nix already has periodic GC
  # nix.gc = {
  #   automatic = true;
  #   interval = {
  #     Weekday = 0;
  #     Hour = 5;
  #     Minute = 0;
  #   };
  #   options = "--delete-older-than 30d";
  # };

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

    # NOTE: ssh agent must be enabled and configured manually in
    # 1password on macos for now
    programs.git.settings.gpg.ssh.program =
      "${pkgs._1password-gui}/Applications/1Password.app/Contents/MacOS/op-ssh-sign";
    programs.jujutsu.settings.signing.backends.ssh.program =
      "${pkgs._1password-gui}/Applications/1Password.app/Contents/MacOS/op-ssh-sign";
  };

  environment.systemPackages = [
    # the agentflow CLI, from the same store path the launchd agent runs, so the
    # two can never disagree about which version of the code is live
    agentflow.af
  ]
  ++ (with pkgs; [
    google-chrome
    boring-notch
    raycast
    monitorcontrol
    orbstack
    jetbrains.datagrip
    obsidian
    _1password-gui
  ]);

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

  # The agentflow orchestrator. A user agent rather than a system daemon on
  # purpose: it needs this user's docker, their gh and jj credentials, their
  # ~/.claude to mount into task containers, and their ~/.local/state to
  # checkpoint into. None of that exists for root.
  launchd.user.agents.agentflow = {
    serviceConfig = {
      ProgramArguments = [ "${agentflow.daemon}/bin/agentflow-daemon" ];
      KeepAlive = true;
      RunAtLoad = true;
      StandardOutPath = agentflowLogPath;
      StandardErrorPath = agentflowLogPath;
      # On stop it checkpoints every running task and kills the agent turns
      # inside their containers, so a later revive does not contend with an
      # orphan on the same claude session. launchd's default 20s deadline can
      # cut that short and leave those orphans behind.
      ExitTimeOut = 60;
      # A crash loop here is usually the port being held by a hand-started
      # daemon; back off rather than spinning on it.
      ThrottleInterval = 10;
      EnvironmentVariables = {
        HOME = "/Users/${user.username}";
        # docker for the task containers, jj for the workspaces, gh for the
        # token it hands them — all the user's own, which is the point.
        #
        # OrbStack's own bin directory goes first so the service resolves docker
        # exactly the way an interactive shell here does. Today both it and the
        # system profile symlink the same store binary, so this changes nothing;
        # it matters the day OrbStack installs a CLI of its own there and the two
        # stop agreeing.
        PATH = "/Users/${user.username}/.orbstack/bin:/etc/profiles/per-user/${user.username}/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin";
        # npm dependencies resolve here rather than into the read-only store
        DENO_DIR = "/Users/${user.username}/Library/Caches/deno";
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
