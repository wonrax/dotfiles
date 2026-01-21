# Improvised based on
# https://github.com/pceiley/nix-config/blob/3854c687d951ee3fe48be46ff15e8e094dd8e89f/hosts/common/modules/qbittorrent.nix

{ pkgs, user, ... }:
{

  systemd.services.qbittorrent = {
    # based on the plex.nix service module and
    # https://github.com/qbittorrent/qBittorrent/blob/master/dist/unix/systemd/qbittorrent-nox%40.service.in
    description = "qBittorrent-nox service";
    documentation = [ "man:qbittorrent-nox(1)" ];
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = rec {
      Type = "simple";
      User = user.username;
      Group = "qbittorrent";

      # Run the pre-start script with full permissions (the "!" prefix) so it
      # can create the data directory if necessary.
      ExecStartPre =
        let
          preStartScript = pkgs.writeScript "qbittorrent-run-prestart" ''
            #!${pkgs.bash}/bin/bash

            # Create data directory if it doesn't exist
            if ! test -d "$QBT_PROFILE"; then
              echo "Creating initial qBittorrent data directory in: $QBT_PROFILE"
              install -d -m 0755 -o "${User}" -g "${Group}" "$QBT_PROFILE"
            fi
          '';
        in
        "!${preStartScript}";

      ExecStart = "${pkgs.qbittorrent-nox}/bin/qbittorrent-nox";
      RequiresMountsFor = [
        "/home/${user.username}/hdd01"
        "/home/${user.username}/hdd02"
      ];
    };

    environment = {
      QBT_PROFILE = "/var/lib/qbittorrent";
      QBT_WEBUI_PORT = "10000";
    };
  };

  users.groups.qbittorrent = { };
}
