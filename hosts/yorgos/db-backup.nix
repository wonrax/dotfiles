{ pkgs, unstablePkgs, ... }:

let
  bucketName = "wrx-sh";
  region = "ap-east-1";
  prefix = "wrx-sh-postgres-backup/";
  filename = "yorgos-backup";
  numVersionsToKeep = 5; # 0 disables pruning
  notifyChannelId = "1410446590472224888";

  backupScript = pkgs.writeShellScript "db-backup.sh" ''
    set -euo pipefail
    set -a

    : "''${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID must be set}"
    : "''${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY must be set}"
    : "''${DISCORD_TOKEN:?DISCORD_TOKEN must be set}"

    now="''$(date +%Y%m%d%H%M%S)"
    file_ext="sql.gz"
    backup_filename="''${now}-${filename}.''${file_ext}"
    fullpath="${bucketName}/${prefix}''${backup_filename}"
    s3_url="s3://''${fullpath}"

    echo "Backing up database and uploading to ''${s3_url}..."

    pg_dumpall -U postgres \
      | gzip \
      | aws s3 cp - "''${s3_url}" --region "${region}"

    # Get the size of the uploaded file
    file_size_bytes="''$(aws s3api head-object --bucket "${bucketName}" --key "${prefix}''${backup_filename}" --region "${region}" --query 'ContentLength' --output text)"
    file_size_mb="''$(echo "scale=2; ''${file_size_bytes} / 1024 / 1024" | bc)"

    discord_content=$(echo '${
      builtins.toJSON {
        content = ''
          ✅ yorgos database has been backed up

          **File:** `$backup_filename`
          **Size:** $file_size_mb MB
          **S3 URL:** `$s3_url`
        '';
      }
    }' | envsubst)

    # Send Discord notification
    echo "Sending Discord notification..."
    curl -H "Content-Type: application/json" \
         -H "Authorization: Bot ''${DISCORD_TOKEN}" \
         -X POST \
         -d "$discord_content" \
         "https://discord.com/api/v10/channels/${notifyChannelId}/messages" \
      || echo "Failed to send Discord notification"

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

    exit 0
  '';

in
{
  systemd.services."db-backup" = {
    description = "Daily PostgreSQL backup to S3 (yorgos)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = with pkgs; [
      awscli2
      bc
      coreutils
      curl
      findutils
      envsubst
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
