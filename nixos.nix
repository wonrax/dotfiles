{ inputs, user, home-manager, ... }:
  [
    # Keyboard remapping
    inputs.xremap-flake.nixosModules.default
    {
      # This configures the service to only run for a specific user
      services.xremap = {
        /* NOTE: since this sample configuration does not have any DE,
        xremap needs to be started manually by systemctl --user start xremap */
        serviceMode = "user";
        userName = user.username;
      };
      # Modmap for single key rebinds
      services.xremap.config.modmap = [
        {
          name = "Global";
          remap = { "CapsLock" = "Esc"; }; # globally remap CapsLock to Esc
        }
      ];
    }

    # make home-manager as a module of nixos
    # so that home-manager configuration will be deployed automatically when executing `nixos-rebuild switch`
    home-manager.nixosModules.home-manager
    {
      home-manager.useUserPackages = true;
      home-manager.extraSpecialArgs = { user = user; };
      home-manager.users.${user.username} = ./home.nix;
    }

    {
      programs.nix-ld.enable = true;
      programs.nix-ld.libraries = [
        # currently only neovim's smart open depends on this
        inputs.nixpkgs.legacyPackages."x86_64-linux".sqlite
      ];
      environment.variables = {
        # Register the nix-ld library path
        LD_LIBRARY_PATH = "$LD_LIBRARY_PATH:$NIX_LD_LIBRARY_PATH";
      };
    }
  ]
