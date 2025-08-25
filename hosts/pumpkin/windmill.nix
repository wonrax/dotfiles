{
  pkgs,
  lib,
  config,
  user,
  ...
}:
let
  windmill = {
    image = "ghcr.io/windmill-labs/windmill:main";
    workerGroups = {
      default.replicas = 1;
      native.replicas = 1;
    };
  };

  envFilePath = config.services.onepassword-secrets.secretPaths.windmill;

  # Create worker configurations with proper sharding indices
  makeWorker = group: index: total: {
    image = windmill.image;
    autoStart = true;
    environmentFiles = [ envFilePath ];
    environment = {
      MODE = "worker";
      WORKER_GROUP = group;
      WORKER_INDEX = toString index;
      WORKER_COUNT = toString total;
    }
    // lib.optionalAttrs (group == "native") {
      NUM_WORKERS = "1";
      SLEEP_QUEUE = "200";
    };
    volumes = lib.optionals (group == "default") [
      "/var/run/docker.sock:/var/run/docker.sock"
      "/var/lib/windmill/cache:/tmp/windmill/cache"
    ];
    extraOptions = [
      "--cpus=1"
      "--memory=256m"
    ];
    dependsOn = [ "windmill-server" ];
  };

  workersForGroup =
    group: total:
    let
      workerNames = map (n: "windmill-worker-${group}-${toString n}") (lib.range 0 (total - 1));
    in
    builtins.listToAttrs (
      map (
        name:
        let
          index = lib.last (lib.splitString "-" name);
        in
        {
          name = name;
          value = makeWorker group (builtins.fromJSON index) total;
        }
      ) workerNames
    );

  # Enhanced Caddyfile configuration
  caddyfile = pkgs.writeText "Caddyfile" ''
    :80 {
      reverse_proxy /ws/* host.docker.internal:8003
      reverse_proxy /* host.docker.internal:8001
    }
  '';

  secretDependentServices = [
    "podman-windmill-server"
  ]
  ++ (map (n: "podman-windmill-worker-default-${toString n}") (
    lib.range 0 (windmill.workerGroups.default.replicas - 1)
  ))
  ++ (map (n: "podman-windmill-worker-native-${toString n}") (
    lib.range 0 (windmill.workerGroups.native.replicas - 1)
  ));
in
{
  # required by default workers that spawn containers to run jobs, making
  # /var/run/docker.sock available to the workers
  virtualisation.podman.dockerSocket.enable = true;

  services.onepassword-secrets.secrets = {
    windmill = {
      reference = "op://host-pumpkin/windmill/envfile";
      owner = user.username;
      services = secretDependentServices;
    };
  };

  # Ensure required directories exist
  systemd.tmpfiles.rules = [
    "d /var/lib/windmill/cache 0755 root root -"
    "d /var/lib/windmill/lsp-cache 0755 root root -"
  ];

  virtualisation.oci-containers.containers = {
    # Windmill Server
    windmill-server = {
      image = windmill.image;
      autoStart = true;
      ports = [
        "8001:8000"
      ];
      environmentFiles = [ envFilePath ];
      environment = {
        MODE = "server";
      };
    };

    # LSP Service
    windmill-lsp = {
      image = "ghcr.io/windmill-labs/windmill-lsp:latest";
      autoStart = true;
      ports = [
        "8003:3001"
      ];
      volumes = [ "/var/lib/windmill/lsp-cache:/pyls/.cache" ];
      dependsOn = [ "windmill-server" ];
    };

    caddy = {
      image = "caddy:2";
      autoStart = true;
      ports = [
        "8000:80"
      ];
      volumes = [
        "${caddyfile}:/etc/caddy/Caddyfile"
      ];
      dependsOn = [
        "windmill-server"
        "windmill-lsp"
      ];
    };
  }
  // (workersForGroup "default" windmill.workerGroups.default.replicas)
  // (workersForGroup "native" windmill.workerGroups.native.replicas);
}
