{
  inputs,
  config,
  user,
  pkgs,
  lib,
  ...
}:
let
  telegramGroupId = "-1003508166716";
  dashboardUrl = "http://pumpkin:9119";
  dashboardAuthFile = "/var/lib/hermes-dashboard/auth.env";
  common = import ../../../home/hermes/common.nix { inherit inputs pkgs lib; };
  inherit (common) sessionResetPolicyPlugin;

in
{
  imports = [ inputs.hermes-agent.nixosModules.default ];

  # The op item must be an env file containing at least:
  #   TELEGRAM_BOT_TOKEN=123456:ABC...
  #   FIRECRAWL_API_KEY=fc-...  (web_search/web_extract backend)
  #   MONEYLOVER_EMAIL=... / MONEYLOVER_PASSWORD=...  (Money Lover MCP)
  # (OPENROUTER_API_KEY may remain for fallback use; the main model now runs
  # via ChatGPT Codex OAuth, whose tokens live in auth.json, not here.)
  # Secret rotations need a rebuild: the module copies environmentFiles into
  # $HERMES_HOME/.env at activation time, not at service start.
  services.onepassword-secrets.secrets.hermesAgentEnv = {
    reference = "op://host-pumpkin/hermes-agent/envfile";
    services = [
      "hermes-agent"
      "hermes-backend"
    ];
  };

  # The hermes module copies environmentFiles into $HERMES_HOME/.env at
  # activation time, but opnix provisions secrets in a systemd service that
  # runs *after* activation — on first deploy the gateway came up with an
  # empty .env ("No messaging platforms enabled"). Feed the secret to the
  # process directly and order the gateway after opnix so a stale .env can
  # never leave it tokenless. ("-" prefix: don't fail if the file is missing.)
  systemd.services.hermes-agent = {
    restartTriggers = [
      sessionResetPolicyPlugin
    ];
    serviceConfig.EnvironmentFile = [
      "-${config.services.onepassword-secrets.secretPaths.hermesAgentEnv}"
      "/var/lib/hermes/mac-node.env"
      dashboardAuthFile
    ];
    after = [
      "opnix-secrets.service"
      "hermes-dashboard-auth.service"
    ];
    wants = [ "opnix-secrets.service" ];
    requires = [ "hermes-dashboard-auth.service" ];
  };

  systemd.services.hermes-dashboard-auth = {
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StateDirectory = "hermes-dashboard";
      StateDirectoryMode = "0700";
      UMask = "0077";
    };
    script = ''
      if [ ! -s ${dashboardAuthFile} ]; then
        password=$(${pkgs.openssl}/bin/openssl rand -hex 24)
        secret=$(${pkgs.openssl}/bin/openssl rand -hex 32)
        printf 'HERMES_DASHBOARD_BASIC_AUTH_USERNAME=${user.username}\nHERMES_DASHBOARD_BASIC_AUTH_PASSWORD=%s\nHERMES_DASHBOARD_BASIC_AUTH_SECRET=%s\n' \
          "$password" "$secret" > ${dashboardAuthFile}.tmp
        mv ${dashboardAuthFile}.tmp ${dashboardAuthFile}
      fi
    '';
  };

  systemd.services.hermes-backend = {
    serviceConfig.EnvironmentFile = [
      "-${config.services.onepassword-secrets.secretPaths.hermesAgentEnv}"
      dashboardAuthFile
    ];
    after = [
      "opnix-secrets.service"
      "hermes-dashboard-auth.service"
    ];
    wants = [ "opnix-secrets.service" ];
    requires = [ "hermes-dashboard-auth.service" ];
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 9119 ];

  # Pin the flake registry's `nixpkgs` to the system's nixpkgs so the agent's
  # ephemeral `nix run nixpkgs#...` invocations resolve to the already-cached
  # rev instead of pulling unstable from the network on every fresh eval.
  nix.registry.nixpkgs.flake = inputs.nixpkgs;

  services.hermes-agent = {
    enable = true;
    addToSystemPackages = true;
    package = common.package;
    extraPlugins = common.extraPlugins;

    backend = {
      mode = "dashboard";
      waitFor = "interface";
      interfaceName = "tailscale0";
      port = 9119;
    };

    environmentFiles = [
      config.services.onepassword-secrets.secretPaths.hermesAgentEnv
      "/var/lib/hermes/mac-node.env"
    ];

    # SOUL.md (agent identity) must live in $HERMES_HOME — `documents` installs
    # into the workspace, where the identity loader never looks. Re-read at
    # every session start, so no restart needed; the agent's own edits are
    # clobbered on deploy (intentional — nix is the source of truth). Replaces
    # the hand-rolled activation script we carried before upstream grew this
    # option.
    hermesHomeFiles."SOUL.md" = pkgs.writeText "hermes-pumpkin-SOUL.md" (
      builtins.readFile ../../../home/hermes/SOUL.md + "\n" + builtins.readFile ./SOUL.md
    );

    # Home channel = where cron results and cross-platform messages land.
    # /sethome persists these same vars into $HERMES_HOME/.env, but nix
    # regenerates that file on every deploy — declare them here instead.
    # Points at the "Life" forum topic; drop THREAD_ID and use "653083546"
    # for DMs instead.
    environment = {
      TELEGRAM_HOME_CHANNEL = telegramGroupId;
      TELEGRAM_HOME_CHANNEL_THREAD_ID = "1";
      TELEGRAM_HOME_CHANNEL_NAME = "Life";
    };

    extraPackages = common.extraPackages ++ [ config.nix.package ];
    mcpServers = common.mcpServers;

    workingDirectory = "/var/lib/hermes/workspace";
    documents = {
      "dreamer/test_memory_schema_compat.py" = ../../../home/hermes/test_memory_schema_compat.py;
    };

    settings = lib.recursiveUpdate common.settings {
      dashboard.public_url = dashboardUrl;
      # Deliver cron output as-is, without the "Cronjob Response: <name>
      # (job_id: ...)" header and "To stop or manage this job" footer.
      cron.wrap_response = false;
      mcp_servers.chauffeur = null;
      a2a_agents.chauffeur = {
        owner_trusted = true;
        url = "http://chauffeur:9900";
        auth = {
          type = "bearer";
          token = "\${HERMES_MAC_A2A_TOKEN}";
        };
        timeout = 300;
        capabilities = [
          "macos"
          "computer_use"
          "code"
        ];
      };

      telegram = {
        # Topic 3 belongs to the Mac bot; Pumpkin handles General only.
        allowed_topics = [
          "1"
        ];
        # Keys are Telegram forum topic IDs.
        channel_prompts = {
          "1" = ''
            This is the "Life" topic. You are the always-on assistant and
            coordinator on Pumpkin: planning, reminders, research,
            accountability, and day-to-day life admin belong here.
            The A2A peer chauffeur runs Hermes on the user's Mac with its own
            agent loop, memory, and local computer-use tools. Delegate tasks
            that need Mac apps, the Mac desktop, or files on that Mac to
            chauffeur. Keep the conversation and coordination here.
            Topic 3 belongs to the separate Mac Telegram bot. Local terminal
            commands in this topic execute on Pumpkin.
          '';

        };
      };
    };
  };
}
