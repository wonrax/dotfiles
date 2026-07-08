{
  lib,
  config,
  user,
  ...
}:
# Cadence — adaptive LLM course studio (ghcr.io/wonrax/cadence). One image,
# two roles selected by the command: migrate (oneshot) → web. Unlike
# household-tasks there is no worker: the web process drains lesson/quiz jobs
# in-process (JOBS_POLL_MS). See ~/code/cadence/DEPLOY.md for the contract this
# module implements.
let
  envFilePath = config.services.onepassword-secrets.secretPaths.cadence;
in
{
  # The opnix item must contain at least:
  #   DATABASE_URL=postgresql://cadence:<pass>@host.containers.internal:5432/cadence
  #   SESSION_SECRET=<random secret; without it prod logins silently break>
  #   LLM_PROVIDER=anthropic            (or openai; unset generates canned content)
  #   ANTHROPIC_API_KEY=<key>           (or OPENAI_API_KEY for the openai provider)
  # NODE_ENV=production and PORT=3000 are already baked into the image.
  # The cadence role + database are created out of band (postgres.nix does not
  # ensure them), same as household-tasks.
  services.onepassword-secrets.secrets = {
    cadence = {
      reference = "op://host-yorgos/cadence/envfile";
      owner = user.username;
      services = [
        "podman-cadence-migrate"
        "podman-cadence-web"
      ];
    };
  };

  # Role + database for the app. ensureDBOwnership makes `cadence` the owner of
  # the `cadence` database — on PostgreSQL 15+ that is also what grants CREATE
  # on the public schema, which drizzle needs to apply migrations. NixOS creates
  # the role with LOGIN but no password; the container connects over TCP with
  # `password` auth (see postgres.nix), so the password must be set once by hand
  # to match DATABASE_URL — nix can't set it without leaking it into the store:
  #   sudo -u postgres psql -c "ALTER ROLE cadence PASSWORD '<pass>'"
  services.postgresql = {
    ensureDatabases = [ "cadence" ];
    ensureUsers = [
      {
        name = "cadence";
        ensureDBOwnership = true;
      }
    ];
  };

  virtualisation.oci-containers.containers = {
    # Applies pending drizzle migrations, then exits 0. Gates web.
    cadence-migrate = {
      image = "ghcr.io/wonrax/cadence:latest";
      cmd = [
        "node"
        "dist/migrate.js"
      ];
      environmentFiles = [ envFilePath ];
      log-driver = "journald";
      extraOptions = [
        "--add-host=host.containers.internal:host-gateway"
      ];
      labels."io.containers.autoupdate" = "registry";
    };

    # SSR + static + server functions + in-process job poller; fronted by
    # Caddy (cadence.wrx.sh).
    cadence-web = {
      image = "ghcr.io/wonrax/cadence:latest";
      # default cmd is `node serve.js`
      ports = [ "3021:3000" ];
      environmentFiles = [ envFilePath ];
      dependsOn = [ "cadence-migrate" ];
      log-driver = "journald";
      extraOptions = [
        "--add-host=host.containers.internal:host-gateway"
      ];
      labels."io.containers.autoupdate" = "registry";
    };
  };

  # Migrate runs once and stays "active" so web can order After it.
  systemd.services."podman-cadence-migrate" = {
    serviceConfig = {
      Type = lib.mkForce "oneshot";
      Restart = lib.mkForce "no";
      RemainAfterExit = true;
    };
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
    partOf = [ "podman-compose-cadence-root.target" ];
    wantedBy = [ "podman-compose-cadence-root.target" ];
  };

  systemd.services."podman-cadence-web" = {
    serviceConfig.Restart = lib.mkOverride 90 "always";
    after = [
      "podman-cadence-migrate.service"
      "postgresql.service"
    ];
    requires = [
      "podman-cadence-migrate.service"
      "postgresql.service"
    ];
    partOf = [ "podman-compose-cadence-root.target" ];
    wantedBy = [ "podman-compose-cadence-root.target" ];
  };

  systemd.targets."podman-compose-cadence-root" = {
    unitConfig.Description = "Root target for Cadence services";
    wantedBy = [ "multi-user.target" ];
  };
}
