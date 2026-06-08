{
  description = "wonrax's nix* configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixpkgs-vlc.url = "github:NixOS/nixpkgs/a9858885e197f984d92d7fe64e9fff6b2e488d40";

    # Pinned to neovim 0.11.6 — 0.12 has breaking changes the plugin ecosystem
    # hasn't caught up with yet.
    nixpkgs-neovim.url = "github:NixOS/nixpkgs/832efc09b4caf6b4569fbf9dc01bec3082a00611";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    xremap-flake = {
      url = "github:xremap/nix-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    minegrub-theme.url = "github:Lxtharia/minegrub-theme";
    minegrub-world-sel-theme = {
      url = "github:Lxtharia/minegrub-world-sel-theme";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

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

    nix = {
      url = "github:NixOS/nix/latest-release";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    starship-jj = {
      url = "gitlab:lanastara_foss/starship-jj";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    dms = {
      url = "github:AvengeMedia/DankMaterialShell/stable";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    dms-plugin-registry = {
      url = "github:AvengeMedia/dms-plugin-registry";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    qylock = {
      url = "github:Darkkal44/qylock";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    niri = {
      url = "github:sodiboo/niri-flake";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
      inputs.nixpkgs-stable.follows = "nixpkgs";
    };

    # Standalone daemon that focuses the source window when a notification is
    # clicked (DMS/quickshell never tells niri to focus the app). Not a flake;
    # packaged in nixos/niri.nix.
    niri-notify-focus = {
      url = "github:Oaklight/niri-notify-focus/v0.2.1";
      flake = false;
    };

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    nix-openclaw = {
      # FIXME: using fork with plugin manifest fix until PR #81 is merged
      # https://github.com/openclaw/nix-openclaw/pull/81
      url = "github:bobberb/nix-openclaw/fix/copy-plugin-manifests";
    };

    diffui = {
      url = "github:wonrax/diffui";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
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
      darwin,
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

      commonSpecialArgs = user: arch: {
        unstablePkgs = nixpkgs-unstable.legacyPackages.${arch};
        inherit
          user
          inputs
          home-manager
          ;
      };

      overlays = final: prev: {
        starship-jj = inputs.starship-jj.packages.${final.stdenv.hostPlatform.system}.default;
        neovim = inputs.nixpkgs-neovim.legacyPackages.${final.stdenv.hostPlatform.system}.neovim;
        diffui = inputs.diffui.packages.${final.stdenv.hostPlatform.system}.default;
      };

      mkDarwin =
        user: darwinStateVersion: homeStateVersion:
        darwin.lib.darwinSystem {
          system = "aarch64-darwin";
          specialArgs = commonSpecialArgs user "aarch64-darwin";
          modules = [
            ./darwin.nix
            {
              nixpkgs.overlays = [ overlays ];
              system.stateVersion = darwinStateVersion;
              home-manager.users.${user.username}.home.stateVersion = homeStateVersion;
            }
          ];
        };

      # Build a deploy-rs node attribute set. The deploy-rs overlay trick lets
      # the local host (which may be a different arch than the target) drive
      # deploys without needing nix's binfmt for the target arch — the actual
      # build still happens on the target unless remoteBuild=false.
      mkDeployNode =
        {
          hostname,
          targetSystem,
          nixosConfig,
          sshUser ? null,
        }:
        system:
        let
          targetPkgs = nixpkgs.legacyPackages.${targetSystem};
          deploy-rs = import nixpkgs {
            system = targetSystem;
            overlays = [
              inputs.deploy-rs.overlays.default
              (_: super: {
                deploy-rs = {
                  inherit (targetPkgs) deploy-rs;
                  lib = super.deploy-rs.lib;
                };
              })
            ];
          };
        in
        {
          inherit hostname;
          profiles.system = {
            user = "root";
            path = deploy-rs.deploy-rs.lib.activate.nixos nixosConfig;
          };
          remoteBuild =
            !(builtins.elem system [
              "aarch64-linux"
              "x86_64-linux"
            ]);
        }
        // nixpkgs.lib.optionalAttrs (sshUser != null) { inherit sshUser; };
    in
    {
      nixosConfigurations.peggy = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = commonSpecialArgs user "x86_64-linux";
        modules = [
          { nixpkgs.overlays = [ overlays ]; }
          ./nixos
          ./hosts/peggy
          inputs.minegrub-theme.nixosModules.default
          inputs.minegrub-world-sel-theme.nixosModules.default
        ];
      };

      darwinConfigurations = {
        wonraxs-macbook-air = mkDarwin user 6 "25.11";
        chauffeur = mkDarwin user 7 "26.05";
        wonraxs-work-macbook = mkDarwin (
          user
          // {
            username = "haiha";
            email = "hai.ha@eastagile.com";
          }
        ) 6 "25.11";
      };

      nixosModules.pumpkin = {
        imports = [
          {
            nixpkgs.overlays = [ overlays ];
          }
          # enable better hardware support for rpi4 rather than generic aarch64
          inputs.nixos-hardware.nixosModules.raspberry-pi-4
          opnix.nixosModules.default
          ./hosts/pumpkin
        ];
      };

      nixosConfigurations.pumpkin = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = commonSpecialArgs user "aarch64-linux";
        modules = [
          self.nixosModules.pumpkin
          # We won't import the generated configuration in sd image builds
          # because it might conflict with the image builder, e.g.:
          # error: The option `fileSystems."/".device' has conflicting definition values
          ./hosts/pumpkin/generated.nix
        ];
      };

      pumpkin-image = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = commonSpecialArgs user "aarch64-linux";
        modules = [
          "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
          self.nixosModules.pumpkin
          # pi-secrets.nix is gitignored and used only when (re)flashing the SD
          # image. Including it here forces `file:.` for the flake arg, which
          # also drags other gitignored files into the store — acceptable for
          # this rare bootstrap path.
          ./pi-secrets.nix
          { sdImage.compressImage = false; }
        ];
      };

      # Use qemu to build the pumpkin image on x86_64-linux.
      # Requires `boot.binfmt.emulatedSystems = [ "aarch64-linux" ];` on the
      # builder host (configured in hosts/peggy/configuration.nix).
      packages.x86_64-linux.pumpkin-image = self.pumpkin-image.config.system.build.sdImage;
      # pkgsCross is avoided here because it rebuilds the whole dependency
      # chain from scratch, which takes comically long compared to binfmt.

      nixosConfigurations.yorgos =
        let
          args = commonSpecialArgs user "x86_64-linux";
        in
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = args;
          modules = [
            { nixpkgs.overlays = [ overlays ]; }
            disko.nixosModules.disko
            opnix.nixosModules.default
            ./hosts/yorgos
          ];
        };

      deploy.nodes =
        let
          deployHosts = [
            "aarch64-darwin"
            "x86_64-linux"
          ];
          mkNodes =
            {
              targetHostname,
              ...
            }@node:
            mapToAttrs deployHosts (system: "from-${system}-to-${targetHostname}") (
              mkDeployNode (removeAttrs node [ "targetHostname" ] // { hostname = targetHostname; })
            );
        in
        mkNodes {
          targetHostname = "pumpkin";
          targetSystem = "aarch64-linux";
          nixosConfig = self.nixosConfigurations.pumpkin;
        }
        // mkNodes {
          targetHostname = "yorgos";
          targetSystem = "x86_64-linux";
          sshUser = "root";
          nixosConfig = self.nixosConfigurations.yorgos;
        };

      apps = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          mkDeployApp = target: {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellScriptBin "deploy-${target}" ''
                #!${pkgs.bash}/bin/bash
                ${pkgs.deploy-rs}/bin/deploy .#from-${system}-to-${target} --auto-rollback false --magic-rollback false --skip-checks
              ''
            );
          };
        in
        {
          deploy-pumpkin = mkDeployApp "pumpkin";
          deploy-yorgos = mkDeployApp "yorgos";
        }
      );
    };
}
