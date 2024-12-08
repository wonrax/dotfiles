{
  description = "wonrax's nix* configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

    home-manager = {
      url = "github:nix-community/home-manager/release-24.11";
      # The `follows` keyword in inputs is used for inheritance.
      # Here, `inputs.nixpkgs` of home-manager is kept consistent with
      # the `inputs.nixpkgs` of the current flake,
      # to avoid problems caused by different versions of nixpkgs.
      inputs.nixpkgs.follows = "nixpkgs";
    };

    xremap-flake.url = "github:xremap/nix-flake";

    # Latest version 0.8.4-RC6 keeps crashing on my system so downgrading to 0.8.2-rc18
    ibus-bamboo = {
      url = "github:NixOS/nixpkgs/0c19708cf035f50d28eb4b2b8e7a79d4dc52f6bb";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      ibus-bamboo,
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
      # Please replace my-nixos with your hostname
      nixosConfigurations.wonrax-desktop-nixos = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit user ibus-bamboo; };
        modules = import ./nixos.nix { inherit inputs user home-manager; } ++ [
          ./hosts/desktop-nixos/configuration.nix
        ];
      };
    };
}
