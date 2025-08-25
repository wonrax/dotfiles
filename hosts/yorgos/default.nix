{
  modulesPath,
  lib,
  pkgs,
  user,
  ...
}@args:
{
  imports = [
    ../server.nix

    (modulesPath + "/installer/scan/not-detected.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
    ./disk-config.nix

    ./postgres.nix
    ./caddy.nix
    ./containers.nix
  ];

  networking.hostName = "yorgos";

  server.swapSize = 4 * 1024; # 4 GiB swap file
  server.opnix.enable = false;

  boot.loader.grub = {
    # no need to set devices, disko will add all devices that have a EF02 partition to the list already
    # devices = [ ];
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  services.openssh.enable = true;

  users.users.root.openssh.authorizedKeys.keys = [
    user.ssh-pub-key
  ]
  ++ (args.extraPublicKeys or [ ]); # this is used for unit-testing this module and can be removed if not needed

  system.stateVersion = "25.05";
}
