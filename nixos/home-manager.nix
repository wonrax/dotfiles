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
  home-manager.users.${user.username} = {
    imports = [
      ../home/desktop.nix
      (
        { pkgs, ... }:
        {
          # TODO: also configure programs.ssh to use 1password ssh-agent,
          # see https://github.com/cbr9/dotfiles/blob/617144/modules/home-manager/ssh/default.nix
          programs.git.settings.gpg.ssh.program = "${pkgs._1password-gui}/bin/op-ssh-sign";
          programs.jujutsu.settings.signing.backends.ssh.program = "${pkgs._1password-gui}/bin/op-ssh-sign";
        }
      )
    ];
  };
}
