{
  user,
  ...
}:
{
  systemd.tmpfiles.rules = [
    "d /var/lib/plex/config 0755 root root -"
  ];

  virtualisation.oci-containers.containers = {
    plex = {
      image = "docker.io/linuxserver/plex:latest";
      autoStart = true;
      ports = [
        "9000:32400"
        "1900:1900/udp"
        "5353:5353/udp"
        "8324:8324"
        "32410:32410/udp"
        "32412:32412/udp"
        "32413:32413/udp"
        "32414:32414/udp"
        "32469:32469"
      ];
      volumes = [
        "/var/lib/plex/config:/config"
        "/home/${user.username}/hdd01:/media"
      ];
      labels = {
        "io.containers.autoupdate" = "registry";
      };
    };
  };
}
