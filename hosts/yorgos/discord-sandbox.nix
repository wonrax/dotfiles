{
  config,
  lib,
  pkgs,
  ...
}:
# The machines the wrx.sh Discord bot runs code on: one rootless podman
# container per channel, owned by the wrx-sandbox user. The api (website.nix)
# creates, starts, stops, and deletes them through that user's podman socket;
# this module is what keeps them in their box. They get their own disk, one
# memory and CPU budget for all of them, and a firewall that lets them reach
# the internet but not this host or any private network.
let
  user = "wrx-sandbox";
  uid = 2000;
  uidStr = toString uid;
  home = "/var/lib/wrx-sandbox";
  # A loop-mounted file, so the sandboxes can't fill the disk Postgres is on.
  # Sparse: it only takes what they use. Grow it with truncate + resize2fs.
  diskImage = "/var/lib/wrx-sandbox.img";
  diskSize = "8G";
  socketDir = "/run/wrx-sandbox";
  podman = config.virtualisation.podman.package;

  # Single-user Nix owned by the container's root, which rootless podman maps
  # to wrx-sandbox on the host. `nixpkgs` resolves to the nixpkgs this host
  # runs, so the image's own packages count as already downloaded.
  nixConf = pkgs.writeTextDir "etc/nix/nix.conf" ''
    experimental-features = nix-command flakes
    build-users-group =
    sandbox = false
    flake-registry = /etc/nix/registry.json
    nix-path = nixpkgs=flake:nixpkgs
    warn-dirty = false
  '';
  nixRegistry = pkgs.writeTextDir "etc/nix/registry.json" (
    builtins.toJSON {
      version = 2;
      flakes = [
        {
          from = {
            type = "indirect";
            id = "nixpkgs";
          };
          to = {
            type = "github";
            owner = "NixOS";
            repo = "nixpkgs";
          }
          // (
            if config.system.nixos.revision != null then
              { rev = config.system.nixos.revision; }
            else
              { ref = "nixos-${config.system.nixos.release}"; }
          );
        }
      ];
    }
  );
  passwd = pkgs.writeTextDir "etc/passwd" ''
    root:x:0:0:root:/home/bot:/bin/bash
    nobody:x:65534:65534:nobody:/var/empty:/bin/false
  '';
  group = pkgs.writeTextDir "etc/group" ''
    root:x:0:
    nobody:x:65534:
  '';

  # The api creates containers from `localhost/wrx-sandbox:latest` and moves a
  # stopped sandbox onto a new image the next time it starts.
  image = pkgs.dockerTools.streamLayeredImage {
    name = "localhost/wrx-sandbox";
    tag = "latest";
    contents = [
      pkgs.dockerTools.binSh
      pkgs.dockerTools.usrBinEnv
      pkgs.dockerTools.caCertificates
      passwd
      group
      nixConf
      nixRegistry
    ]
    ++ (with pkgs; [
      bashInteractive
      coreutils
      curl
      diffutils
      findutils
      gawk
      git
      gnugrep
      gnused
      gnutar
      gzip
      jq
      less
      nix
      procps
      python3
      ripgrep
      tini
      which
      xz
    ]);
    includeNixDB = true;
    fakeRootCommands = ''
      mkdir -p ./tmp ./var/tmp ./home/bot
      chmod 1777 ./tmp ./var/tmp
    '';
    config = {
      Entrypoint = [
        (lib.getExe pkgs.tini)
        "--"
      ];
      Cmd = [
        "${pkgs.coreutils}/bin/sleep"
        "infinity"
      ];
      WorkingDir = "/home/bot";
      Env = [
        "HOME=/home/bot"
        "USER=root"
        "PATH=/home/bot/.local/bin:/bin:/usr/bin"
        "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
        "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
        "LANG=C.UTF-8"
        "PAGER=cat"
        "GIT_TERMINAL_PROMPT=0"
      ];
    };
  };

  # Outgoing traffic of every process of wrx-sandbox, pasta's included, which
  # carries the containers' traffic. Packets without an owning socket don't
  # match `meta skuid`, so the host's own traffic never reaches the sandbox
  # chain. Containers resolve through public DNS: this host's resolver is
  # tailscale's, out of their reach.
  egressRules = pkgs.writeText "wrx-sandbox-egress.nft" ''
    table inet wrx_sandbox
    delete table inet wrx_sandbox
    table inet wrx_sandbox {
      chain output {
        type filter hook output priority filter; policy accept;
        meta skuid ${uidStr} jump sandbox
      }

      chain sandbox {
        # This host, on any of its addresses: Postgres and every other service
        oifname "lo" reject
        ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/3 } reject
        ip6 daddr { ::/128, ::1/128, fc00::/7, fe80::/10, ff00::/8 } reject
        # Sending mail, or scanning ports, gets the host an abuse report
        tcp dport { 25, 465, 587 } reject
        ct state new limit rate over 50/second burst 100 packets drop
      }
    }
  '';
in
{
  assertions = [
    {
      # The nftables module flushes the whole ruleset, this table included
      assertion = !config.networking.nftables.enable;
      message = "Move the wrx_sandbox table of discord-sandbox.nix into networking.nftables.tables.";
    }
  ];

  users.groups.${user}.gid = uid;
  users.users.${user} = {
    isSystemUser = true;
    inherit uid home;
    group = user;
    createHome = false;
    linger = true;
    autoSubUidGidRange = true;
  };

  systemd.tmpfiles.rules = [
    "d ${socketDir} 0700 ${user} ${user} -"
  ];

  systemd.services.wrx-sandbox-disk = {
    description = "Disk of the Discord bot's sandboxes";
    wantedBy = [ "multi-user.target" ];
    path = [
      pkgs.e2fsprogs
      pkgs.util-linux
    ];
    # Remounting would pull the disk from under running sandboxes
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if [ ! -e ${diskImage} ]; then
        truncate --size ${diskSize} ${diskImage}
        mkfs.ext4 -q -m 0 ${diskImage}
      fi
      mkdir -p ${home}
      if ! mountpoint --quiet ${home}; then
        mount -o loop ${diskImage} ${home}
      fi
      chown ${user}:${user} ${home}
      chmod 0700 ${home}
    '';
  };

  systemd.services.wrx-sandbox-egress = {
    description = "Firewall of the Discord bot's sandboxes";
    wantedBy = [ "multi-user.target" ];
    # Swapped in place: a restart would restart the sandbox user's manager
    reloadIfChanged = true;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.nftables}/bin/nft -f ${egressRules}";
      ExecReload = "${pkgs.nftables}/bin/nft -f ${egressRules}";
      ExecStop = "${pkgs.nftables}/bin/nft delete table inet wrx_sandbox";
    };
  };

  # Nothing of wrx-sandbox runs before its disk and firewall are in place
  systemd.services."user@${uidStr}" = {
    overrideStrategy = "asDropin";
    requires = [
      "wrx-sandbox-disk.service"
      "wrx-sandbox-egress.service"
    ];
    after = [
      "wrx-sandbox-disk.service"
      "wrx-sandbox-egress.service"
    ];
    # Rootless podman can only set container limits on delegated controllers
    serviceConfig.Delegate = "cpu cpuset io memory pids";
  };

  # All the sandboxes together, on top of each container's own limits. yorgos
  # has about a gigabyte to spare.
  systemd.slices."user-${uidStr}" = {
    overrideStrategy = "asDropin";
    sliceConfig = {
      MemoryMax = "1G";
      MemorySwapMax = "512M";
      CPUQuota = "150%";
      TasksMax = 2048;
    };
  };

  # The api's way in. Socket-activated, so podman runs only while it's used.
  systemd.user.sockets.wrx-sandbox-podman = {
    description = "Podman API of the Discord bot's sandboxes";
    wantedBy = [ "sockets.target" ];
    unitConfig.ConditionUser = user;
    socketConfig = {
      ListenStream = "${socketDir}/podman.sock";
      SocketMode = "0600";
    };
  };

  systemd.user.services.wrx-sandbox-podman = {
    description = "Podman API of the Discord bot's sandboxes";
    unitConfig.ConditionUser = user;
    requires = [ "wrx-sandbox-podman.socket" ];
    after = [ "wrx-sandbox-podman.socket" ];
    # newuidmap and newgidmap
    path = [ "/run/wrappers" ];
    serviceConfig = {
      Type = "exec";
      # The containers outlive the API server, which exits when idle
      KillMode = "process";
      Delegate = true;
      ExecStart = "${lib.getExe podman} system service";
    };
  };

  systemd.services.wrx-sandbox-image = {
    description = "Image of the Discord bot's sandboxes";
    wantedBy = [ "multi-user.target" ];
    requires = [ "user@${uidStr}.service" ];
    after = [ "user@${uidStr}.service" ];
    path = [
      "/run/wrappers"
      podman
    ];
    environment = {
      XDG_RUNTIME_DIR = "/run/user/${uidStr}";
      DBUS_SESSION_BUS_ADDRESS = "unix:path=/run/user/${uidStr}/bus";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = user;
      Group = user;
    };
    script = ''
      set -o pipefail
      ${image} | podman load
      podman image prune --force
    '';
  };
}
