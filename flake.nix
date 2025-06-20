{
  description = "wonrax's nix* configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixpkgs-vlc.url = "github:NixOS/nixpkgs/a9858885e197f984d92d7fe64e9fff6b2e488d40";

    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    xremap-flake = {
      url = "github:xremap/nix-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    minegrub-theme.url = "github:Lxtharia/minegrub-theme";
    minegrub-world-sel-theme.url = "github:Lxtharia/minegrub-world-sel-theme";

    opnix = {
      url = "github:brizzbuzz/opnix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    crane.url = "github:ipetkov/crane";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      home-manager,
      nixpkgs-unstable,
      opnix,
      nixpkgs,
      ...
    }@inputs:
    let
      user = {
        username = "wonrax";
        fullname = "Hai L. Ha-Huy";
        email = "hahuylonghai2012@gmail.com";

        # 1password general SSH key
        ssh-pub-key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILcVnyW/bNR+hbNQ4utoprtSm8ONNFMER9lgLT9u9rVu";
      };
    in
    rec {
      nixosConfigurations.peggy = nixpkgs.lib.nixosSystem {
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
            ./hosts/peggy
            inputs.minegrub-theme.nixosModules.default
            inputs.minegrub-world-sel-theme.nixosModules.default
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
            inherit user inputs;
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

      nixosModules.pumpkin = {
        imports = [
          opnix.nixosModules.default
          ./hosts/pumpkin
          ./pi-secrets.nix
        ];
      };

      # NOTE: this can be built on ARM darwin without any config, how??
      # For x86_64-linux, it might requires emulatedSystems though
      nixosConfigurations.pumpkin = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = { inherit user; };
        modules = [
          nixosModules.pumpkin
          # We won't import the generated configuration in sd image builds
          # because it might get conflict with image builder, e.g.:
          # error: The option `fileSystems."/".device' has conflicting definition values
          ./hosts/pumpkin/generated.nix
        ];
      };

      pumpkin-image = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = { inherit user; };
        modules = [
          "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
          nixosModules.pumpkin
          (
            { ... }:
            {
              sdImage.compressImage = false;
            }
          )
        ];
      };

      # Use qemu to build the pumpkin image on x86_64-linux
      # requires `boot.binfmt.emulatedSystems = [ "aarch64-linux" ];`
      # TODO: detect if emulatedSystems is set, and if not, throw an error
      packages.x86_64-linux.images.pumpkin = pumpkin-image.config.system.build.sdImage;

      pumpkin-image-pkgsCross =
        nixpkgs.legacyPackages.x86_64-linux.pkgsCross.aarch64-multiplatform.nixos
          {
            imports = [
              "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
              nixosModules.pumpkin
            ];
          };

      # NOTE: using pkgsCross will rebuild entire dependency chain from
      # scratch, which can takes comically long.
      packages.aarch64-darwin.images.pumpkin = pumpkin-image-pkgsCross.config.system.build.sdImage;
    };
}
