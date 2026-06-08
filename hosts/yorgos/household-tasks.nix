{
  lib,
  config,
  user,
  pkgs,
  ...
}:
# Nhà — household task tracker. One image (ghcr.io/wonrax/household-tasks),
# three roles selected by the command: migrate (oneshot) → web + worker.
# See ~/code/household-tasks/DEPLOY.md for the contract this module implements.
let
  envFilePath = config.services.onepassword-secrets.secretPaths.householdTasks;
in
{
  # The opnix item must contain at least:
  #   DATABASE_URL=postgresql://nha:<pass>@host.containers.internal:5432/nha
  #   ADMIN_TOKEN=<secret gating /admin>
  # (plus VAPID_SUBJECT/VAPID_PUBLIC_KEY/VAPID_PRIVATE_KEY once web push is wired up).
  services.onepassword-secrets.secrets = {
    householdTasks = {
      reference = "op://host-yorgos/household-tasks/envfile";
      owner = user.username;
      services = [
        "podman-household-tasks-migrate"
        "podman-household-tasks-web"
        "podman-household-tasks-worker"
      ];
    };
  };

  systemd.services."podman-network-household-tasks" = {
    path = [ pkgs.podman ];
    serviceConfig = {
      Restart = lib.mkForce "no";
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStop = "podman network rm -f household-tasks";
    };
    script = ''
      podman network inspect household-tasks || podman network create household-tasks
    '';
    partOf = [ "podman-compose-household-tasks-root.target" ];
    wantedBy = [ "podman-compose-household-tasks-root.target" ];
  };

  virtualisation.oci-containers.containers = {
    # Applies pending migrations, then exits 0. Gates web + worker.
    household-tasks-migrate = {
      image = "ghcr.io/wonrax/household-tasks:latest";
      cmd = [
        "node"
        "dist/migrate.js"
      ];
      environmentFiles = [ envFilePath ];
      log-driver = "journald";
      extraOptions = [
        "--network=household-tasks"
        "--add-host=host.containers.internal:host-gateway"
      ];
      labels."io.containers.autoupdate" = "registry";
    };

    # SSR + static + server functions; fronted by Caddy (nha.wrx.sh).
    household-tasks-web = {
      image = "ghcr.io/wonrax/household-tasks:latest";
      # default cmd is `node serve.js`
      ports = [ "3020:3000" ];
      environmentFiles = [ envFilePath ];
      dependsOn = [ "household-tasks-migrate" ];
      log-driver = "journald";
      extraOptions = [
        "--network=household-tasks"
        "--add-host=host.containers.internal:host-gateway"
      ];
      labels."io.containers.autoupdate" = "registry";
    };

    # Drains the notification outbox. No inbound ports.
    household-tasks-worker = {
      image = "ghcr.io/wonrax/household-tasks:latest";
      cmd = [
        "node"
        "dist/worker.js"
      ];
      environmentFiles = [ envFilePath ];
      dependsOn = [ "household-tasks-migrate" ];
      log-driver = "journald";
      extraOptions = [
        "--network=household-tasks"
        "--add-host=host.containers.internal:host-gateway"
      ];
      labels."io.containers.autoupdate" = "registry";
    };
  };

  # Migrate runs once and stays "active" so dependents can order After it.
  systemd.services."podman-household-tasks-migrate" = {
    serviceConfig = {
      Type = lib.mkForce "oneshot";
      Restart = lib.mkForce "no";
      RemainAfterExit = true;
    };
    after = [
      "podman-network-household-tasks.service"
      "postgresql.service"
    ];
    requires = [
      "podman-network-household-tasks.service"
      "postgresql.service"
    ];
    partOf = [ "podman-compose-household-tasks-root.target" ];
    wantedBy = [ "podman-compose-household-tasks-root.target" ];
  };

  systemd.services."podman-household-tasks-web" = {
    serviceConfig.Restart = lib.mkOverride 90 "always";
    after = [
      "podman-network-household-tasks.service"
      "podman-household-tasks-migrate.service"
      "postgresql.service"
    ];
    requires = [
      "podman-network-household-tasks.service"
      "podman-household-tasks-migrate.service"
      "postgresql.service"
    ];
    partOf = [ "podman-compose-household-tasks-root.target" ];
    wantedBy = [ "podman-compose-household-tasks-root.target" ];
  };

  systemd.services."podman-household-tasks-worker" = {
    serviceConfig.Restart = lib.mkOverride 90 "always";
    after = [
      "podman-network-household-tasks.service"
      "podman-household-tasks-migrate.service"
      "postgresql.service"
    ];
    requires = [
      "podman-network-household-tasks.service"
      "podman-household-tasks-migrate.service"
      "postgresql.service"
    ];
    partOf = [ "podman-compose-household-tasks-root.target" ];
    wantedBy = [ "podman-compose-household-tasks-root.target" ];
  };

  systemd.targets."podman-compose-household-tasks-root" = {
    unitConfig.Description = "Root target for Nhà (household-tasks) services";
    wantedBy = [ "multi-user.target" ];
  };
}
