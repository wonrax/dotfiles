{
  pkgs,
  config,
  user,
  lib,
  ...
}:
let
  vectorSettings = {
    sources = {
      journald.type = "journald";
      vector_metrics.type = "internal_metrics";
      host_metrics.type = "host_metrics";
    };

    sinks = {
      newrelic_metrics = {
        type = "new_relic";
        inputs = [
          "vector_metrics"
          "host_metrics"
        ];
        account_id = "4240358";
        api = "metrics";
        license_key = "$NRIA_LICENSE_KEY";
        region = "eu";
      };
      newrelic_logs = {
        type = "new_relic";
        inputs = [ "journald" ];
        account_id = "4240358";
        api = "logs";
        license_key = "$NRIA_LICENSE_KEY";
        region = "eu";
      };
    };
  };
in
{
  services.onepassword-secrets.secrets = {
    vector = {
      reference = "op://host-pumpkin/vector/envfile";
      owner = user.username;
    };
  };

  systemd.services.vector = {
    description = "Vector event and log aggregator";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    requires = [ "network-online.target" ];
    serviceConfig =
      let
        format = pkgs.formats.toml { };
        conf = format.generate "vector.toml" vectorSettings;
      in
      {
        ExecStart = "${lib.getExe pkgs.vector} --config ${conf}  --graceful-shutdown-limit-secs 30";
        DynamicUser = true;
        Restart = "always";
        StateDirectory = "vector";
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        AmbientCapabilities = "CAP_NET_BIND_SERVICE";
        # This group is required for accessing journald.
        SupplementaryGroups = "systemd-journal";
        EnvironmentFile = config.services.onepassword-secrets.secretPaths.vector;
      };
    unitConfig = {
      StartLimitIntervalSec = 10;
      StartLimitBurst = 5;
    };
  };
}
