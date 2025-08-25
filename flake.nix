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

    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
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
      disko,
      ...
    }@inputs:
    let
      mapToAttrs =
        list: keyFn: valueFn:
        nixpkgs.lib.listToAttrs (map (item: nixpkgs.lib.nameValuePair (keyFn item) (valueFn item)) list);

      forAllSystems =
        fn:
        nixpkgs.lib.genAttrs [
          "x86_64-linux"
          "aarch64-darwin"
        ] fn;

      user = {
        username = "wonrax";
        fullname = "Hai L. Ha-Huy";
        email = "hahuylonghai2012@gmail.com";

        # 1password general SSH key
        ssh-pub-key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILcVnyW/bNR+hbNQ4utoprtSm8ONNFMER9lgLT9u9rVu";
      };
    in
    {
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
      # TODO: libsqlite3 is not yet managed by home-manager, gotta install it
      # manually using brew
      legacyPackages.aarch64-darwin.homeConfigurations.${user.username} =
        home-manager.lib.homeManagerConfiguration
          {
            pkgs = nixpkgs.legacyPackages.aarch64-darwin;
            extraSpecialArgs = {
              unstablePkgs = nixpkgs-unstable.legacyPackages.aarch64-darwin;
              inherit user inputs;
            };
            modules = [
              ./home/desktop.nix
              {
                home.stateVersion = "24.11";

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

      nixosModules.pumpkin = {
        imports = [
          opnix.nixosModules.default
          ./hosts/pumpkin

          # TODO: by importing gitignored files, we had to use file:. in flake
          # arg. This means that other gitignored files will also be copied
          # into the nix store, which can be huge.
          # Fix this by using proper secret management solutions for nix
          ./pi-secrets.nix
        ];
      };

      nixosConfigurations.pumpkin = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = {
          inherit user inputs;
        };
        modules = [
          self.nixosModules.pumpkin
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
          self.nixosModules.pumpkin
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
      packages.x86_64-linux.pumpkin-image = self.pumpkin-image.config.system.build.sdImage;

      # TODO: failing checks
      # pumpkin-image-pkgsCross =
      #   nixpkgs.legacyPackages.aarch64-darwin.pkgsCross.aarch64-multiplatform.nixos
      #     {
      #       imports = [
      #         "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
      #         self.nixosModules.pumpkin
      #       ];
      #     };

      # NOTE: using pkgsCross will rebuild entire dependency chain from
      # scratch, which can takes comically long.
      # packages.aarch64-darwin.pumpkin-image = self.pumpkin-image-pkgsCross.config.system.build.sdImage;

      nixosConfigurations.yorgos = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {
          inherit user inputs;
          unstablePkgs = nixpkgs-unstable.legacyPackages.x86_64-linux;
        };
        modules = [
          disko.nixosModules.disko
          opnix.nixosModules.default
          ./hosts/yorgos
        ];
      };

      deploy.nodes =
        (mapToAttrs
          [
            "aarch64-darwin"
            "x86_64-linux"
          ]
          (system: system + "-pumpkin")
          (
            system:
            let
              targetSystem = "aarch64-linux";
              deploy-rs =
                let
                  pkgs = nixpkgs.legacyPackages."${targetSystem}";
                in
                import nixpkgs {
                  system = targetSystem;
                  overlays = [
                    inputs.deploy-rs.overlays.default
                    (self: super: {
                      deploy-rs = {
                        inherit (pkgs) deploy-rs;
                        lib = super.deploy-rs.lib;
                      };
                    })
                  ];
                };
            in
            {
              hostname = "pumpkin";
              profiles.system = {
                user = "root";
                path = deploy-rs.deploy-rs.lib.activate.nixos self.nixosConfigurations.pumpkin;
              };
              remoteBuild =
                !(builtins.elem system [
                  "aarch64-linux"
                  "x86_64-linux"
                ]);
            }
          )
        )
        // (mapToAttrs
          [
            "aarch64-darwin"
            "x86_64-linux"
          ]
          (system: system + "-yorgos")
          (
            system:
            let
              targetSystem = "x86_64-linux";
              deploy-rs =
                let
                  pkgs = nixpkgs.legacyPackages."${targetSystem}";
                in
                import nixpkgs {
                  system = targetSystem;
                  overlays = [
                    inputs.deploy-rs.overlays.default
                    (self: super: {
                      deploy-rs = {
                        inherit (pkgs) deploy-rs;
                        lib = super.deploy-rs.lib;
                      };
                    })
                  ];
                };
            in
            {
              sshUser = "root";
              hostname = "yorgos";
              profiles.system = {
                user = "root";
                path = deploy-rs.deploy-rs.lib.activate.nixos self.nixosConfigurations.yorgos;
              };
              remoteBuild =
                !(builtins.elem system [
                  "aarch64-linux"
                  "x86_64-linux"
                ]);
            }
          )
        );

      apps = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages."${system}";
        in
        {
          deploy-pumpkin = {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellScriptBin "deploy-pumpkin" ''
                #!${pkgs.bash}/bin/bash
                ${pkgs.deploy-rs}/bin/deploy path:.#${system}-pumpkin --skip-checks
              ''
            );
          };

          deploy-yorgos = {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellScriptBin "deploy-yorgos" ''
                #!${pkgs.bash}/bin/bash
                ${pkgs.deploy-rs}/bin/deploy .#${system}-yorgos --skip-checks
              ''
            );
          };
        }
      );

      # deploy-rs checks
      checks = builtins.mapAttrs (
        system: deployLib: deployLib.deployChecks self.deploy
      ) inputs.deploy-rs.lib;
    };
}
