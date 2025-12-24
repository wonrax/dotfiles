{
  lib,
  config,
  user,
  pkgs,
  ...
}:
let
  envFilePath = config.services.onepassword-secrets.secretPaths.affine;
in
{
  # Ensure required directories exist
  systemd.tmpfiles.rules = [
    "d /var/lib/affine/storage 0755 root root -"
    "d /var/lib/affine/config 0755 root root -"
  ];

  # 1Password secrets for database credentials
  services.onepassword-secrets.secrets = {
    affine = {
      reference = "op://host-yorgos/affine/envfile";
      owner = user.username;
      services = [
        "podman-affine"
        "podman-affine-migration"
      ];
    };
  };

  # Network for AFFiNE services
  systemd.services."podman-network-affine" = {
    path = [ pkgs.podman ];
    serviceConfig = {
      Restart = lib.mkForce "no";
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStop = "podman network rm -f affine";
    };
    script = ''
      podman network inspect affine || podman network create affine
    '';
    partOf = [ "podman-compose-affine-root.target" ];
    wantedBy = [ "podman-compose-affine-root.target" ];
  };

  virtualisation.oci-containers.containers = {
    # Redis for AFFiNE
    affine-redis = {
      image = "docker.io/redis:latest";
      autoStart = true;
      extraOptions = [
        "--health-cmd=redis-cli --raw incr ping"
        "--health-interval=10s"
        "--health-timeout=5s"
        "--health-retries=5"
        "--network=affine"
      ];
      labels = {
        "io.containers.autoupdate" = "registry";
      };
    };

    # AFFiNE Migration (runs once before main service)
    affine-migration = {
      image = "ghcr.io/toeverything/affine:stable";
      autoStart = true;
      cmd = [
        "sh"
        "-c"
        "node ./scripts/self-host-predeploy.js"
      ];
      environmentFiles = [ envFilePath ];
      environment = {
        REDIS_SERVER_HOST = "affine-redis";
        AFFINE_INDEXER_ENABLED = "false";
      };
      volumes = [
        "/var/lib/affine/storage:/root/.affine/storage:rw"
        "/var/lib/affine/config:/root/.affine/config:rw"
      ];
      extraOptions = [
        "--network=affine"
      ];
      labels = {
        "io.containers.autoupdate" = "registry";
      };
    };

    # AFFiNE Main Server
    affine = {
      image = "ghcr.io/toeverything/affine:stable";
      autoStart = true;
      ports = [ "3010:3010" ];
      environmentFiles = [ envFilePath ];
      environment = {
        REDIS_SERVER_HOST = "affine-redis";
        AFFINE_INDEXER_ENABLED = "false";
        AFFINE_SERVER_EXTERNAL_URL = "https://a.wrx.sh";
      };
      volumes = [
        "/var/lib/affine/storage:/root/.affine/storage:rw"
        "/var/lib/affine/config:/root/.affine/config:rw"
      ];
      extraOptions = [
        "--network=affine"
      ];
      labels = {
        "io.containers.autoupdate" = "registry";
      };
    };
  };

  # Redis service config
  systemd.services."podman-affine-redis" = {
    serviceConfig = {
      Restart = lib.mkOverride 90 "always";
    };
    after = [ "podman-network-affine.service" ];
    requires = [ "podman-network-affine.service" ];
    partOf = [ "podman-compose-affine-root.target" ];
    wantedBy = [ "podman-compose-affine-root.target" ];
  };

  # Migration service config (oneshot)
  systemd.services."podman-affine-migration" = {
    serviceConfig = {
      Type = lib.mkForce "oneshot";
      Restart = lib.mkForce "no";
      RemainAfterExit = true;
    };
    after = [
      "podman-network-affine.service"
      "podman-affine-redis.service"
      "postgresql.service"
    ];
    requires = [
      "podman-network-affine.service"
      "podman-affine-redis.service"
      "postgresql.service"
    ];
    partOf = [ "podman-compose-affine-root.target" ];
    wantedBy = [ "podman-compose-affine-root.target" ];
  };

  # Main AFFiNE service config
  systemd.services."podman-affine" = {
    serviceConfig = {
      Restart = lib.mkOverride 90 "always";
    };
    after = [
      "podman-network-affine.service"
      "podman-affine-redis.service"
      "podman-affine-migration.service"
      "postgresql.service"
    ];
    requires = [
      "podman-network-affine.service"
      "podman-affine-redis.service"
      "podman-affine-migration.service"
      "postgresql.service"
    ];
    partOf = [ "podman-compose-affine-root.target" ];
    wantedBy = [ "podman-compose-affine-root.target" ];
  };

  # Root target for AFFiNE compose
  systemd.targets."podman-compose-affine-root" = {
    unitConfig = {
      Description = "Root target for AFFiNE services";
    };
    wantedBy = [ "multi-user.target" ];
  };
}
