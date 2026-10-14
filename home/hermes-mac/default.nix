{
  config,
  lib,
  pkgs,
  user,
  inputs,
  ...
}:
let
  cfg = config.services.hermes-mac;
  home = "/Users/${user.username}";
  state = "${home}/.local/state/hermes-mac";
  app = "${home}/Applications/CuaDriver.app";
  driver = "${app}/Contents/MacOS/cua-driver";
  hermesHome = "${home}/.hermes";
  installPython = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
  common = import ../hermes/common.nix { inherit inputs pkgs lib; };
  hermesPackage = common.package;
  workerConfig = (pkgs.formats.yaml { }).generate "hermes-mac-config.yaml" (
    lib.recursiveUpdate common.settings {
      computer_use.backend = "cua";
      plugins.enabled = common.settings.plugins.enabled ++ [ "cua" ];
      gateway.platforms.a2a = {
        enabled = true;
        extra.port = 9900;
      };
      mcp_servers = lib.recursiveUpdate common.mcpServers common.settings.mcp_servers;
      telegram = {
        allowed_topics = [ "3" ];
        channel_prompts."3" = ''
          This is the Mac topic. You run directly on chauffeur with your own
          Hermes agent loop and local tools. Local terminal commands and
          computer-use actions execute on this Mac. Pumpkin is the always-on
          coordinator for the cluster.
        '';
      };
    }
  );
  soul = pkgs.writeText "hermes-mac-SOUL.md" (
    builtins.readFile ../hermes/SOUL.md + "\n" + builtins.readFile ./SOUL.md
  );
  cli = pkgs.writeShellScriptBin "hermes" ''
    export HERMES_HOME=${lib.escapeShellArg hermesHome}
    export HERMES_CUA_DRIVER_CMD=${lib.escapeShellArg driver}
    export CUA_DRIVER_RS_TELEMETRY_ENABLED=0
    export PATH=${lib.makeBinPath common.extraPackages}:"$PATH"
    export A2A_HOST=100.65.46.20
    export A2A_OWNER_PEERS=pumpkin
    export A2A_MAX_PINGPONG_TURNS=20
    export TELEGRAM_HOME_CHANNEL=-1003508166716
    export TELEGRAM_HOME_CHANNEL_THREAD_ID=3
    export TELEGRAM_HOME_CHANNEL_NAME=Mac
    if [ "''${1:-}" = desktop ] || [ "''${1:-}" = gui ]; then
      shift
      exec ${state}/runtime-a2a/bin/hermes-desktop "$@"
    fi
    exec ${hermesPackage}/bin/hermes "$@"
  '';
  desktop = hermesPackage.hermesDesktop.override {
    hermesAgent = cli;
    extraEnv.HERMES_HOME = hermesHome;
  };
  archive = pkgs.fetchurl {
    url = "https://github.com/trycua/cua/releases/download/cua-driver-rs-v0.21.0/cua-driver-rs-0.21.0-darwin-universal.tar.gz";
    sha256 = "f827a393c0dae24943ddb454d85abb6b592d8636e6a99f6c349f81f5f516975f";
  };
  bundle = pkgs.runCommand "cua-driver-0.21.0-signed-bundle" { } ''
    mkdir -p $out
    tar -xzf ${archive} -C $out --strip-components=1
  '';
  install = pkgs.writeShellScriptBin "hermes-mac-install" ''
    set -eu
    mkdir -p ${lib.escapeShellArg state} ${lib.escapeShellArg "${home}/Applications"}
    chmod 700 ${lib.escapeShellArg state}
    if [ ! -d ${lib.escapeShellArg app} ]; then
      /usr/bin/ditto ${bundle}/CuaDriver.app ${lib.escapeShellArg app}
    elif [ "$(${lib.escapeShellArg driver} --version)" != "cua-driver 0.21.0" ]; then
      echo "Existing CuaDriver version differs from the pinned 0.21.0; update the app before installing the worker." >&2
      exit 1
    fi
    /usr/bin/codesign --verify --deep --strict ${lib.escapeShellArg app}
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ${lib.escapeShellArg app}
    mkdir -p ${lib.escapeShellArg hermesHome}
    chmod 700 ${lib.escapeShellArg hermesHome}
    ${installPython}/bin/python3 - ${workerConfig} ${lib.escapeShellArg "${hermesHome}/config.yaml"} <<'PY'
    import pathlib, sys, yaml
    source, target = map(pathlib.Path, sys.argv[1:])
    current = yaml.safe_load(target.read_text()) or {} if target.exists() else {}
    def merge(old, new):
        for key, value in new.items():
            if isinstance(value, dict) and isinstance(old.get(key), dict):
                merge(old[key], value)
            else:
                old[key] = value
        return old
    if target.exists():
        backup = target.with_suffix(".yaml.before-node")
        backup.write_bytes(target.read_bytes())
        backup.chmod(0o600)
    target.write_text(yaml.safe_dump(merge(current, yaml.safe_load(source.read_text()))))
    target.chmod(0o600)
    PY
    mkdir -p ${lib.escapeShellArg "${hermesHome}/plugins"}
    /bin/ln -sfn ${common.sessionResetPolicyPlugin} ${lib.escapeShellArg "${hermesHome}/plugins/nix-managed-hermes-session-reset-policy"}
    /bin/cp ${soul} ${lib.escapeShellArg "${hermesHome}/SOUL.md"}
    echo "Installed CuaDriver. Grant desktop access with: ${driver} permissions grant"
  '';
  gateway = pkgs.writeShellScript "hermes-mac-gateway" ''
    exec ${cli}/bin/hermes gateway
  '';
  service = name: script: {
    serviceConfig = {
      ProgramArguments = [ "${script}" ];
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 10;
      StandardOutPath = "${state}/${name}.log";
      StandardErrorPath = "${state}/${name}.log";
      EnvironmentVariables = {
        HOME = home;
        PATH = "/etc/profiles/per-user/${user.username}/bin:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
        CUA_DRIVER_RS_TELEMETRY_ENABLED = "0";
      };
    };
  };
  node = pkgs.runCommand "hermes-mac-node" { } ''
    mkdir -p $out/bin
    ln -s ${install}/bin/hermes-mac-install $out/bin/hermes-mac-install
    ln -s ${cli}/bin/hermes $out/bin/hermes
    ln -s ${gateway} $out/bin/hermes-mac-gateway
    ln -s ${desktop}/bin/hermes-desktop $out/bin/hermes-desktop
  '';
in
{
  options.services.hermes-mac.enable = lib.mkEnableOption "Mac Hermes A2A worker for Pumpkin's gateway";
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ node ];
    launchd.user.agents.hermes-mac-gateway = service "gateway" gateway;
  };
}
