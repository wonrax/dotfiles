{ pkgs, unstablePkgs, ... }:

let
  bucketName = "wrx-sh";
  region = "ap-east-1";
  prefix = "wrx-sh-postgres-backup/";
  filename = "yorgos-backup";
  numVersionsToKeep = 5; # 0 disables pruning

  backupScript = pkgs.writeShellScript "db-backup.sh" ''
    set -euo pipefail

    : "''${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID must be set}"
    : "''${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY must be set}"

    now="''$(date +%Y%m%d%H%M%S)"
    file_ext="sql.gz"

    fullpath="${bucketName}/${prefix}''${now}-${filename}.''${file_ext}"

    echo "Backing up database and uploading to s3://''${fullpath}..."

    pg_dumpall -U postgres \
      | gzip \
      | aws s3 cp - "s3://''${fullpath}" --region "${region}"

    if [ "${builtins.toString numVersionsToKeep}" = "0" ]; then
      echo "Retention disabled; keeping all versions."
      exit 0
    fi

    echo "Removing older versions (if any)..."
    files="''$(aws s3api list-objects --region "${region}" --bucket "${bucketName}" \
      --prefix "${prefix}" \
      --query 'Contents[].{Key: Key}' \
      --output text || true)"

    if [ -n "''${files}" ]; then
      echo "''${files}" \
        | grep -oE "^${prefix}[0-9]{14}-${filename}\\.''${file_ext}$" \
        | sort -r \
        | tail -n "+${builtins.toString (numVersionsToKeep + 1)}" \
        | xargs -r -I {} aws s3 rm "s3://${bucketName}/{}" --region "${region}"
    fi

    echo "success"
  '';

in
{
  systemd.services."db-backup" = {
    description = "Daily PostgreSQL backup to S3 (yorgos)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = with pkgs; [
      awscli2
      coreutils
      findutils
      gnugrep
      gzip
      unstablePkgs.postgresql_18 # use the same postgres version as the server
    ];

    serviceConfig = {
      EnvironmentFile = "/etc/wrx-sh/.env";
      Type = "oneshot";
      User = "postgres";
      ExecStart = backupScript;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      RestrictSUIDSGID = true;
      RestrictRealtime = true;
      DevicePolicy = "closed";
      CapabilityBoundingSet = "";
      SystemCallFilter = "@system-service";
      ReadWritePaths = [
        "/tmp"
        "/run"
      ];
    };
  };

  systemd.timers."db-backup" = {
    description = "Timer for daily PostgreSQL backup to S3 (yorgos)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "10m";
    };
  };
}
