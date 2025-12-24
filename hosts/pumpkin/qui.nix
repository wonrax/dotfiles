{
  user,
  ...
}:
{
  systemd.tmpfiles.rules = [
    "d /var/lib/qui/data 0755 root root -"
  ];

  virtualisation.oci-containers.containers = {
    qui = {
      image = "ghcr.io/autobrr/qui:latest";
      autoStart = true;
      environment = {
        QUI__DATA_DIR = "/qui/data";
        QUI__HOST = "0.0.0.0";
        QUI__PORT = "7476";
        QUI__SESSION_SECRET = "this service is not exposed to the internet, so this is probably fine";
      };
      ports = [ "7476:7476" ];
      volumes = [
        "/var/lib/qui/data:/qui/data"
        # "Several qui features require access to the same filesystem paths
        # that qBittorrent uses"
        # https://getqui.com/docs/getting-started/docker#local-filesystem-access
        "/home/${user.username}/hdd01:/home/${user.username}/hdd01"
        "/home/${user.username}/hdd02:/home/${user.username}/hdd02"
      ];
      labels = {
        "io.containers.autoupdate" = "registry";
      };
    };
  };
}
