# MetaDefender Core (pkgs/mdcore.nix) as a set of systemd services.
#
# This stands in for the deb's maintainer scripts and units. The product
# hardcodes FHS paths and writes into its own install dir, so the services
# run in a mount namespace that puts everything where it expects:
#
#   /usr/lib/ometascan  <- /var/lib/ometascan-install/lib (mutable copy of the package's tree)
#   /etc/ometascan      <- /var/lib/ometascan-install/etc (seeded once, then yours)
#   /usr/sbin, /usr/bin, /bin <- small store dirs with the package's tools plus
#                          the coreutils-ish binaries it shells out to
#
# Nothing is written under /usr or /etc on the host apart from the empty mount
# points systemd creates for those binds.
#
# Engines are downloaded by MD Core at runtime and aren't patched, so they run
# through nix-ld. The extra nix-ld libraries are added only while this module
# is enabled: dropping `services.mdcore.enable` (or this import) takes them out
# of the system closure, so the next GC collects them.
#
# Departures from the deb:
# - No setcap: the services get the same capabilities as ambient caps instead,
#   since /usr/sbin is a read-only store bind and file caps can't be set there.
# - No sudoers drop-in for ocmapplicationupgrader. In-app upgrades would run
#   dpkg against a system that has none; upgrade by bumping pkgs/mdcore.nix.
# - No 32-bit support. Some engines want libc6-i386/lib32stdc++6, which nix-ld
#   doesn't cover. Those engines will fail to load until that's sorted out.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.mdcore;
  pkg = cfg.package;

  installDir = "/var/lib/ometascan-install";

  # The daemon and the engines' shell scripts (preflight checks, wrappers)
  # expect a Debian-ish userland: #!/bin/bash, awk, `ldd --version`, and a
  # few absolute paths like /usr/bin/gzip and /bin/kill. This set is bound
  # over /bin and /usr/bin in the services' namespace and put on PATH.
  tools = pkgs.buildEnv {
    name = "mdcore-tools";
    paths = with pkgs; [
      bash
      coreutils
      gawk
      gnugrep
      gnused
      findutils
      diffutils
      procps
      util-linux
      glibc.bin # ldd, getconf
      which
      file
      gzip
      gnutar
      xz
      bzip2
      unzip
      config.systemd.package
    ];
    pathsToLink = [ "/bin" ];
  };
  binDir = pkgs.runCommand "mdcore-bin" { } ''
    mkdir -p $out
    ln -s ${tools}/bin/* $out/
    ln -sf ${pkg}/usr/bin/* $out/
  '';

  # The deb's postinst also chowns the install dir, so these runtime files
  # land next to the binaries and must survive a resync.
  runtimeFiles = [
    "ometascan_postgres.dat"
    "ometascan_postgres.dat.shared"
    "ometascan_postgres.cat"
    "pg14.dat"
    "pg18.dat"
    "patches/"
    "postgres-old/"
    "bat/"
  ];

  # Shared by every unit so they all see the same filesystem.
  namespace = {
    BindPaths = [
      "${installDir}/lib:/usr/lib/ometascan"
      "${installDir}/etc:/etc/ometascan"
    ]
    ++ lib.optional (cfg.ignitionFile == null) "${installDir}/opswat:/etc/opswat";
    BindReadOnlyPaths = [
      "${pkg}/usr/sbin:/usr/sbin"
      "${binDir}:/usr/bin"
      "${binDir}:/bin"
    ]
    ++ lib.optional (cfg.ignitionFile != null) "${cfg.ignitionFile}:/etc/opswat/ometascan.conf";
  };

  # Only the engine libraries, not nix-ld's whole default set, so nothing on
  # LD_LIBRARY_PATH shadows the daemon's bundled OpenSSL/Qt/libxml2.
  engineLibs = pkgs.buildEnv {
    name = "mdcore-engine-libs";
    paths = map lib.getLib cfg.engineLibraries;
    pathsToLink = [ "/lib" ];
  };

  nixLdEnv = {
    NIX_LD = "/run/current-system/sw/share/nix-ld/lib/ld.so";
    NIX_LD_LIBRARY_PATH = "/run/current-system/sw/share/nix-ld/lib";
  };

  setup = pkgs.writeShellScript "mdcore-setup" ''
    set -euo pipefail
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.rsync
      ]
    }

    install -d -o metascan -g metascan -m 0755 /run/ometascan /var/tmp/ometascan
    chgrp metascan ${installDir}/opswat
    chmod 0750 ${installDir}/opswat

    stamp=${installDir}/.package
    if [ "$(cat "$stamp" 2>/dev/null)" != "${pkg}" ]; then
      echo "Syncing ${pkg} into ${installDir}"
      rsync -a --delete --chmod=u+w \
        ${lib.concatMapStringsSep " " (f: "--exclude=/${f}") runtimeFiles} \
        ${pkg}/usr/lib/ometascan/ ${installDir}/lib/
      rsync -a --delete --chmod=u+w \
        ${pkg}/var/lib/ometascan/html/ /var/lib/ometascan/html/
      echo "${pkg}" > "$stamp"
    fi

    ${lib.optionalString (cfg.ignitionFile == null) ''
      # MD Core refuses to set up its bundled PostgreSQL without an ignition
      # file naming the superuser it should create.
      ignition=/etc/opswat/ometascan.conf
      if [ ! -s $ignition ]; then
        echo "Generating $ignition"
        (umask 077; cat > $ignition) <<EOF
      [dbserver]
      type=local
      host=localhost
      port=5432
      user=postgres
      password=$(head -c 24 /dev/urandom | base64 | tr -d '/+=')
      EOF
        chgrp metascan $ignition
        chmod 0640 $ignition
      fi
    ''}
    if [ ! -e ${installDir}/etc/ometascan.conf ]; then
      cp -r --no-preserve=mode ${pkg}/etc/ometascan/. ${installDir}/etc/
    fi

    mkdir -p /var/lib/ometascan/engines /var/log/ometascan/enginelogs/preflight
    chown -R metascan:metascan ${installDir}/lib /var/lib/ometascan /var/log/ometascan

    # Creates or migrates the bundled PostgreSQL. postinst runs it as root on
    # every install/upgrade; it drops to metascan for postgres by itself.
    /usr/sbin/ometascan-upgrade-db

    chown -R metascan:metascan /var/lib/ometascan ${installDir}/lib
  '';
in
{
  options.services.mdcore = {
    enable = lib.mkEnableOption "OPSWAT MetaDefender Core";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/mdcore.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ../pkgs/mdcore.nix { }";
    };

    ignitionFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/mdcore-ignition.conf";
      description = ''
        Runtime path to an ignition file (admin account, license key,
        PostgreSQL settings, ...), mounted at /etc/opswat/ometascan.conf. A
        string rather than a path so the secrets in it stay out of the store.
        When null, one with just a random local PostgreSQL password is
        generated in ${installDir}/opswat.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Plays the role of /etc/default/ometascan (proxy variables).";
    };

    engineLibraries = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = with pkgs; [
        stdenv.cc.cc.lib # libstdc++, libgcc_s, libgomp
        zlib
        db53
        libxcrypt-legacy
        fontconfig
        freetype
        libx11
        libxext
        libxrender
        ncurses5 # libtinfo.so.5 / libncurses.so.5 (Deep CDR)
        libnsl # Deep CDR
        libgdiplus # Deep CDR
        xz # liblzma: FileType, Archive Compression, Deep CDR, Deflection
        zstd # FileType, Archive Compression, Deep CDR
        bzip2 # FileType, Deep CDR
        expat # Archive Compression
        libxcb # Deep CDR's ImageMagick and cairo
      ];
      description = ''
        Libraries for the unpatched, runtime-downloaded engines. Most engines
        are oms_engine.so plugins dlopened into the (patched) engineprocess,
        which only finds them through LD_LIBRARY_PATH; engine executables go
        through nix-ld. Both get this set. Add to it when an engine fails to
        load.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    programs.nix-ld = {
      enable = true;
      libraries = cfg.engineLibraries;
    };

    users.users.metascan = {
      isSystemUser = true;
      group = "metascan";
      extraGroups = [ "systemd-journal" ];
      home = "/var/tmp/ometascan";
      description = "metascan daemon";
    };
    users.groups.metascan = { };

    systemd.services.ometascan-setup = {
      description = "MetaDefender Core install/upgrade steps";
      serviceConfig = namespace // {
        Type = "oneshot";
        RemainAfterExit = true;
        # Created before the namespace is set up, so the binds' sources exist.
        StateDirectory = [
          "ometascan"
          "ometascan-install"
          "ometascan-install/lib"
          "ometascan-install/etc"
          "ometascan-install/opswat"
        ];
        LogsDirectory = "ometascan";
        ExecStart = setup;
        Environment = lib.mapAttrsToList (n: v: "${n}=${v}") nixLdEnv;
      };
    };

    systemd.services.ometascan-pg = {
      description = "MetaDefender Core PostgreSQL";
      requires = [ "ometascan-setup.service" ];
      after = [ "ometascan-setup.service" ];
      wantedBy = [ "multi-user.target" ];
      # On first boot the daemon runs initdb itself; until then this is skipped.
      unitConfig.ConditionPathExists = "/var/lib/ometascan/pg_data/PG_VERSION";
      environment = {
        OPENSSL_CONF = "/var/lib/ometascan/pg_data/openssl-active.cnf";
        OPENSSL_MODULES = "/usr/lib/ometascan/postgres/lib/ossl-modules";
      };
      serviceConfig = namespace // {
        Type = "forking";
        User = "metascan";
        Group = "metascan";
        PIDFile = "/var/lib/ometascan/pg_data/postmaster.pid";
        ExecStart = "/usr/lib/ometascan/postgres/bin/pg_ctl start -w -D /var/lib/ometascan/pg_data";
        ExecStop = "/usr/lib/ometascan/postgres/bin/pg_ctl stop -w -D /var/lib/ometascan/pg_data";
        ExecReload = "/usr/lib/ometascan/postgres/bin/pg_ctl reload -D /var/lib/ometascan/pg_data";
        Restart = "on-failure";
        RestartSec = 30;
      };
    };

    # On first boot the daemon runs initdb and then waits ~30s for PostgreSQL
    # to come up, expecting `systemctl start ometascan-pg` from its own
    # (unprivileged) process to start it. That fails, so start it from here.
    systemd.paths.ometascan-pg = {
      wantedBy = [ "multi-user.target" ];
      pathConfig.PathExists = "/var/lib/ometascan/pg_data/PG_VERSION";
    };

    systemd.services.ometascan = {
      description = "MetaDefender Core server";
      requires = [ "ometascan-setup.service" ];
      after = [
        "ometascan-setup.service"
        "ometascan-pg.service"
        "network-online.target"
      ];
      wants = [
        "ometascan-pg.service"
        "network-online.target"
      ];
      wantedBy = [ "multi-user.target" ];
      environment = nixLdEnv // {
        LD_LIBRARY_PATH = "${engineLibs}/lib";
      };
      path = [ tools ];
      serviceConfig = namespace // {
        Type = "simple";
        User = "metascan";
        Group = "metascan";
        PIDFile = "/run/ometascan/ometascan.pid";
        AmbientCapabilities = [
          "CAP_SETUID"
          "CAP_SETGID"
          "CAP_FOWNER"
          "CAP_CHOWN"
        ];
        # nginx (the web UI) is spawned by the daemon and can outlive it.
        ExecStartPre = "-${pkgs.bash}/bin/sh -c '${pkgs.procps}/bin/kill $(cat /run/ometascan/ometascan-nginx.pid) 2>/dev/null'";
        ExecStart = "/usr/sbin/ometascan";
        ExecStopPost = "-${pkgs.bash}/bin/sh -c '${pkgs.procps}/bin/kill $(cat /run/ometascan/ometascan-nginx.pid) 2>/dev/null'";
        EnvironmentFile = lib.mkIf (cfg.environmentFile != null) cfg.environmentFile;
        LimitNOFILE = 65535;
        Restart = "on-failure";
        RestartSec = 30;
      };
    };
  };
}
