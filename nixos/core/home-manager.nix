{
  inputs,
  user,
  home-manager,
  unstablePkgs,
  ...
}:
{
  # Run home-manager as a NixOS module so HM activates on every
  # `nixos-rebuild switch`.
  imports = [ home-manager.nixosModules.home-manager ];

  home-manager.useUserPackages = true;
  home-manager.useGlobalPkgs = true;
  home-manager.extraSpecialArgs = { inherit user unstablePkgs inputs; };
  home-manager.users.${user.username}.imports = [ ../../home/common.nix ];
}
