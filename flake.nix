{
  description = "wonrax's nix* configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixpkgs-vlc.url = "github:NixOS/nixpkgs/a9858885e197f984d92d7fe64e9fff6b2e488d40";

    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      # The `follows` keyword in inputs is used for inheritance.
      # Here, `inputs.nixpkgs` of home-manager is kept consistent with
      # the `inputs.nixpkgs` of the current flake,
      # to avoid problems caused by different versions of nixpkgs.
      inputs.nixpkgs.follows = "nixpkgs";
    };

    xremap-flake = {
      url = "github:xremap/nix-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    minegrub-theme.url = "github:Lxtharia/minegrub-theme";
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      nixpkgs-unstable,
      ...
    }@inputs:
    let
      user = {
        username = "wonrax";
        fullname = "Hai L. Ha-Huy";
        email = "hahuylonghai2012@gmail.com";
      };
    in
    {
      nixosConfigurations.wonrax-desktop-nixos = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {
          inherit user;
        };
        modules =
          import ./nixos.nix {
            unstablePkgs = nixpkgs-unstable.legacyPackages.x86_64-linux;
            inherit
              inputs
              user
              home-manager
              ;
          }
          ++ [
            ./hosts/desktop-nixos/configuration.nix
            inputs.minegrub-theme.nixosModules.default
          ];
      };

      # Standalone home-manager configuration, for systems where you don't want
      # to use NixOS but still want to use home-manager, e.g. macOS without
      # nix-darwin.
      packages.aarch64-darwin = {
        # TODO: libsqlite3 is not yet managed by home-manager, gotta install it
        # manually using brew
        homeConfigurations.${user.username} = home-manager.lib.homeManagerConfiguration {
          pkgs = nixpkgs.legacyPackages.aarch64-darwin;
          extraSpecialArgs = {
            unstablePkgs = nixpkgs-unstable.legacyPackages.aarch64-darwin;
            inherit user;
          };
          modules = [
            ./home.nix
            {
              # NOTE: ssh agent must be enabled and configured manually in
              # 1password on macos for now
              programs.git = {
                extraConfig = {
                  gpg.ssh.program = "/Applications/1Password.app/Contents/MacOS/op-ssh-sign";
                };
              };
              programs.jujutsu = {
                settings.signing.backends.ssh.program = "/Applications/1Password.app/Contents/MacOS/op-ssh-sign";
              };
            }
          ];
        };
      };
    };
}
