{
  modulesPath,
  user,
  config,
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
    ./website.nix
    ./open-webui.nix
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

  virtualisation.podman.enable = true;

  # Allow pulling arbitrary container images from the internet.
  environment.etc."policy.json".text = ''
    {
      "default": [{"type": "insecureAcceptAnything"}]
    }
  '';

  # Enable container name DNS for all Podman networks.
  networking.firewall.interfaces =
    let
      matchAll = if !config.networking.nftables.enable then "podman+" else "podman*";
    in
    {
      "${matchAll}".allowedUDPPorts = [ 53 ];
    };

  virtualisation.oci-containers.backend = "podman";

  server.vector = {
    enable = true;
    environmentFiles = [ /etc/vector/.env ];
  };

  system.stateVersion = "25.05";
}
