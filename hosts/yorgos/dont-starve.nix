{
  lib,
  config,
  user,
  pkgs,
  ...
}:
let
  envFilePath = config.services.onepassword-secrets.secretPaths.dontStarve;

  # Caves roughly double the cluster's memory footprint and yorgos is
  # memory-constrained (the api service alone holds ~1.6 GiB), so the second
  # shard is opt-in until the box has headroom.
  cavesEnabled = false;

  clusterName = "EA Starve Together";
  maxPlayers = 12;

  workshopMods = [
    "378160973" # Global Positions
    "2189004162" # Insight (Show Me+)
    # The original Wormhole Marks (362175979) is abandoned and crashes on
    # current game builds, so use the maintained fork.
    "3571706033" # Wormhole Marks [DST Continued]
    "1207269058" # Simple Health Bar DST
    "1595631294" # Smart Minisign
  ];

  # dedicated_server_mods_setup.lua makes the server download the mods on
  # boot; modoverrides.lua (per shard) is what actually enables them.
  modsSetupLua = lib.concatMapStringsSep "\n" (id: ''ServerModSetup("${id}")'') workshopMods;
  modOverridesLua =
    "return {\n"
    + lib.concatMapStringsSep "\n" (id: "  [\"workshop-${id}\"] = { enabled = true },") workshopMods
    + "\n}";

  # DST has no nixpkgs package and the community docker images are abandoned
  # (jamesits/dst-server last released 2018), so we run our own entrypoint on
  # the actively maintained steamcmd base image. steamcmd re-checks the game
  # on every container start, which keeps the server version-matched with
  # game clients after Klei updates — restarting the unit is updating.
  entrypoint = pkgs.writeShellScript "dst-entrypoint" (
    ''
      set -euo pipefail

      if [ -z "''${DST_CLUSTER_TOKEN:-}" ]; then
        echo "DST_CLUSTER_TOKEN is not set; generate one at https://accounts.klei.com/account/game/servers" >&2
        exit 1
      fi

      # The 64-bit server needs the gnutls flavor of libcurl which the steamcmd
      # image doesn't ship. The container is ephemeral so this runs every start.
      dpkg -s libcurl3-gnutls >/dev/null 2>&1 || {
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends libcurl3-gnutls
      }

      INSTALL_DIR=/data/server
      CLUSTER_DIR=/data/DoNotStarveTogether/Cluster_1

      # steamcmd misbehaves from a virgin HOME (bogus "Missing configuration"
      # / "Missing file permissions" errors on any app_update), and current
      # builds install into the HOME library ignoring force_install_dir — so
      # persist the entire steam home under /data, seeded once from the
      # image's pre-initialized copy. Game files then survive restarts
      # wherever steamcmd decides to put them.
      if [ ! -d /data/steam-home/Steam ]; then
        rm -rf /data/steam-home.tmp /data/steam-home
        cp -a /home/steam /data/steam-home.tmp
        mv /data/steam-home.tmp /data/steam-home
      fi
      export HOME=/data/steam-home

      # || true: find exits nonzero when a search root doesn't exist (e.g.
      # steamcmd ignored force_install_dir so /data/server was never made),
      # which set -e would turn fatal at the BIN="$(find_bin)" call site
      # even though the binary was found under the other root.
      find_bin() {
        {
          find "$INSTALL_DIR" "$HOME/Steam/steamapps" \
            -type f -path '*bin64*' -name 'dontstarve_dedicated_server_nullrenderer*' \
            2>/dev/null || true
        } | head -n 1
      }

      # steamcmd's exit codes are unreliable, so retry a few times and judge
      # success by whether the server binary materialized. If an update
      # attempt fails but a previous install exists, run with that rather
      # than crash-looping; the next restart retries the update.
      for attempt in 1 2 3 4; do
        /home/steam/steamcmd/steamcmd.sh \
          +force_install_dir "$INSTALL_DIR" \
          +login anonymous \
          +app_update 343050 validate \
          +quit || true
        if [ -n "$(find_bin)" ]; then
          break
        fi
        echo "steamcmd attempt $attempt failed; retrying in 10s" >&2
        sleep 10
      done

      mkdir -p "$CLUSTER_DIR/Master"

      # Config files are regenerated on every start so this module stays the
      # source of truth; saves live in the shard dirs and are never touched.
      # cluster_key only authenticates loopback shard traffic inside the
      # container, so it's not a real secret.
      cat > "$CLUSTER_DIR/cluster.ini" <<EOF
      [GAMEPLAY]
      game_mode = survival
      max_players = ${toString maxPlayers}
      pvp = false
      pause_when_empty = true

      [NETWORK]
      cluster_name = ${clusterName}
      cluster_password = ''${DST_CLUSTER_PASSWORD:-}
      cluster_intention = cooperative
      cluster_language = en

      [MISC]
      console_enabled = true

      [SHARD]
      shard_enabled = ${lib.boolToString cavesEnabled}
      bind_ip = 127.0.0.1
      master_ip = 127.0.0.1
      master_port = 10888
      cluster_key = local-shard-key
      EOF

      printf '%s\n' "$DST_CLUSTER_TOKEN" > "$CLUSTER_DIR/cluster_token.txt"

      cat > "$CLUSTER_DIR/Master/server.ini" <<EOF
      [NETWORK]
      server_port = 10999

      [SHARD]
      is_master = true

      [STEAM]
      master_server_port = 27018
      authentication_port = 8768
      EOF

      cat > "$CLUSTER_DIR/Master/modoverrides.lua" <<EOF
      ${modOverridesLua}
      EOF
    ''
    + lib.optionalString cavesEnabled ''
      mkdir -p "$CLUSTER_DIR/Caves"

      cat > "$CLUSTER_DIR/Caves/server.ini" <<EOF
      [NETWORK]
      server_port = 11000

      [SHARD]
      is_master = false
      name = Caves

      [STEAM]
      master_server_port = 27019
      authentication_port = 8769
      EOF

      cat > "$CLUSTER_DIR/Caves/modoverrides.lua" <<EOF
      ${modOverridesLua}
      EOF

      # Without the cave preset the second shard would generate another surface
      # world. Only read at world generation; safe to rewrite afterwards.
      cat > "$CLUSTER_DIR/Caves/worldgenoverride.lua" <<EOF
      return {
        override_enabled = true,
        preset = "DST_CAVE",
      }
      EOF
    ''
    + ''
      BIN="$(find_bin)"
      if [ -z "$BIN" ]; then
        echo "no server binary found under $INSTALL_DIR or $HOME/Steam/steamapps" >&2
        exit 1
      fi
      # The mods dir sits next to bin64 in the game root, wherever steamcmd
      # ended up installing it.
      GAME_ROOT="$(dirname "$(dirname "$BIN")")"
      mkdir -p "$GAME_ROOT/mods"
      cat > "$GAME_ROOT/mods/dedicated_server_mods_setup.lua" <<EOF
      ${modsSetupLua}
      EOF

      cd "$(dirname "$BIN")"
      BIN="./$(basename "$BIN")"

      run_shard() {
        "$BIN" \
          -persistent_storage_root /data \
          -conf_dir DoNotStarveTogether \
          -cluster Cluster_1 \
          -shard "$1"
      }

      pids=()
      # Forward SIGTERM so the shards save the world before exiting.
      trap 'kill -TERM "''${pids[@]}" 2>/dev/null || true' TERM INT

    ''
    + lib.optionalString cavesEnabled ''
      run_shard Caves &
      pids+=($!)

    ''
    + ''
      run_shard Master &
      pids+=($!)

      wait || true
      wait || true
    ''
  );
in
{
  systemd.tmpfiles.rules = [
    "d /var/lib/dont-starve 0750 root root -"
  ];

  services.onepassword-secrets.secrets.dontStarve = {
    reference = "op://host-yorgos/dont-starve/envfile";
    owner = user.username;
    services = [ "podman-dont-starve" ];
  };

  virtualisation.oci-containers.containers.dont-starve = {
    image = "docker.io/cm2network/steamcmd:root-bookworm";
    autoStart = true;
    environmentFiles = [ envFilePath ];
    volumes = [
      "/var/lib/dont-starve:/data:rw"
      "${entrypoint}:/entrypoint.sh:ro"
    ];
    entrypoint = "/bin/bash";
    cmd = [ "/entrypoint.sh" ];
    ports = [
      "10999:10999/udp"
    ]
    ++ lib.optionals cavesEnabled [ "11000:11000/udp" ];
    extraOptions = [
      # Hard cap so a long-lived world can't OOM postgres or the mail server;
      # if DST hits it, the unit restarts and the world reloads from the last
      # save instead of taking the box down.
      "--memory=${if cavesEnabled then "2600m" else "1500m"}"
      # Leave time for world saving on shutdown before podman sends SIGKILL.
      "--stop-timeout=30"
    ];
  };

  systemd.services."podman-dont-starve".serviceConfig = {
    Restart = lib.mkOverride 90 "always";
    # Space out crash loops (e.g. a Steam outage) so the unit doesn't hit
    # systemd's start rate limit within seconds.
    RestartSec = 30;
  };

  networking.firewall.allowedUDPPorts = [
    10999
  ]
  ++ lib.optionals cavesEnabled [ 11000 ];
}
