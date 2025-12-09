{
  pkgs,
  home-manager,
  user,
  unstablePkgs,
  inputs,
  ...
}:
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
    home.stateVersion = "25.11"; # TODO: move this to host specific

    home.sessionVariables = {
      # I don't have time for this bro, will fix later
      DYLD_LIBRARY_PATH = "${pkgs.lib.makeLibraryPath (with pkgs; [ sqlite ])}:$DYLD_LIBRARY_PATH";
    };

    home.packages = with pkgs; [
      google-chrome
    ];

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

  # Add ability to used TouchID for sudo authentication
  security.pam.services.sudo_local.touchIdAuth = true;
  system = {
    primaryUser = user.username;
    defaults = {
      NSGlobalDomain.KeyRepeat = 999;
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

  system.stateVersion = 6; # TODO: move this to host specific
}
