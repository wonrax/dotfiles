{
  modulesPath,
  user,
  config,
  lib,
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
    ./db-backup.nix
    ./windmill.nix
    ./affine.nix
    ./stalwart-mail.nix
  ];

  networking.hostName = "yorgos";
  networking.domain = "wrx.sh";

  networking = {
    interfaces.enp1s0.ipv6.addresses = [
      {
        address = "2a01:4ff:2f0:3705::1";
        prefixLength = 64;
      }
    ];
    defaultGateway6 = {
      address = "fe80::1";
      interface = "enp1s0";
    };
  };

  server.swapSize = 4 * 1024; # 4 GiB swap file
  server.opnix.enable = true;

  boot.loader.grub = {
    # no need to set devices, disko will add all devices that have a EF02 partition to the list already
    # devices = [ ];
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  services.openssh.enable = true;
  services.cockpit = {
    enable = true;
    settings = {
      WebService = {
        AllowUnencrypted = true;
        Origins = lib.mkForce "*";
      };
    };
  };

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
  home-manager.users.${user.username}.home.stateVersion = "25.05";
}
