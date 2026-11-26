{
  inputs,
  config,
  user,
  pkgs,
  unstablePkgs,
  lib,
  ...
}:
let
  telegramGroupId = "-1003508166716";
  dashboardUrl = "http://pumpkin:9119";
  dashboardAuthFile = "/var/lib/hermes-dashboard/auth.env";
  common = import ../../../home/hermes/common.nix { inherit inputs pkgs unstablePkgs lib; };
  inherit (common) sessionResetPolicyPlugin claudeSubscriptionPlugin githubCopilotPlugin;

in
{
  imports = [ inputs.hermes-agent.nixosModules.default ];

  # The op item must be an env file containing at least:
  #   TELEGRAM_BOT_TOKEN=123456:ABC...
  #   FIRECRAWL_API_KEY=fc-...  (web_search/web_extract backend)
  #   MONEYLOVER_EMAIL=... / MONEYLOVER_PASSWORD=...  (Money Lover MCP)
  #   OPENCODE_GO_API_KEY=...  (optional OpenCode Go provider)
  #   CLAUDE_CODE_OAUTH_TOKEN=...  (from `claude setup-token`; the main model's
  #     claude-subscription-directsdk provider passes it to the `claude` CLI)
  #   COPILOT_GITHUB_TOKEN=ghu_...  (from `hermes auth add copilot`; the plugin's
  #     401 refresh only re-exchanges env tokens, not device-login pool rows)
  # (OPENROUTER_API_KEY may remain for fallback use; the ChatGPT Codex OAuth
  # tokens for the openai-codex provider live in auth.json, not here.)
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
    # The module writes config.yaml and .env from an activation script, so
    # config changes leave the unit untouched and the running gateway keeps
    # the old values. Hash them into the unit instead. (mcpServers lands in
    # settings.mcp_servers; SOUL.md and documents are read fresh per session;
    # opnix restarts the unit itself when the secret env file rotates.)
    restartTriggers = [
      sessionResetPolicyPlugin
      claudeSubscriptionPlugin
      githubCopilotPlugin
      (builtins.toJSON config.services.hermes-agent.settings)
      (builtins.toJSON config.services.hermes-agent.environment)
    ];
    preStart = lib.mkAfter ''
      ln -sfn ${githubCopilotPlugin} ${config.services.hermes-agent.stateDir}/.hermes/plugins/github-copilot
    '';
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

  # Allow Hermes to trigger a NixOS switch strictly from GitHub's `main` branch
  # without sudo or root access: nothing deploys until a PR is reviewed/merged.
  systemd.services.pumpkin-deploy = {
    description = "Deploy Pumpkin NixOS configuration from github:wonrax/dotfiles#pumpkin";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    restartIfChanged = false;
    stopIfChanged = false;
    path = [
      config.nix.package
      pkgs.git
      pkgs.openssh
    ];
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "pumpkin-deploy";
      StateDirectoryMode = "0755";
    };
    script = ''
      set -euo pipefail
      log="/var/lib/pumpkin-deploy/last.log"
      {
        echo "=== pumpkin-deploy started $(date -Is) ==="
        ${config.system.build.nixos-rebuild}/bin/nixos-rebuild switch \
          --flake github:wonrax/dotfiles#pumpkin \
          --refresh
        echo "=== pumpkin-deploy finished $(date -Is) ==="
      } 2>&1 | tee "$log"
    '';
  };

  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (
        action.id == "org.freedesktop.systemd1.manage-units" &&
        action.lookup("unit") == "pumpkin-deploy.service" &&
        action.lookup("verb") == "start" &&
        subject.user == "hermes"
      ) {
        return polkit.Result.YES;
      }
    });
  '';

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

    extraPackages = common.extraPackages ++ [
      config.nix.package
      pkgs.chromium
    ];
    mcpServers = common.mcpServers;

    workingDirectory = "/var/lib/hermes/workspace";
    documents = {
      "dreamer/python-with-source.sh" = ../../../home/hermes/python-with-source.sh;
      "dreamer/run.sh" = ../../../home/hermes/dreamer-run.sh;
      "dreamer/test_memory_schema_compat.py" = ../../../home/hermes/test_memory_schema_compat.py;
    };

    settings = lib.recursiveUpdate common.settings {
      dashboard.public_url = dashboardUrl;
      # NixOS can't run Hermes's dynamically-linked pm Chromium (exit 127 under
      # stub-ld); point browser_exec at NixOS's pkgs.chromium instead.
      browser.executable_path = "${pkgs.chromium}/bin/chromium";
      # Hermes's media delivery denylist blocks /var/lib, which collides with
      # this NixOS service's home/workspace under /var/lib/hermes and silently
      # drops MEDIA: attachments. Allowlist workspace + scratch explicitly.
      gateway.media_delivery_allow_dirs = [
        "/var/lib/hermes/workspace"
        "/var/lib/hermes/.hermes/cache/scratch"
      ];
      # Shared agent skills, copied into the store: the hermes system user
      # can't see the home-manager ~/.agents link.
      skills.external_dirs = [ "${../../../.config/agents/skills}" ];
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
        # The module deep-merges config.yaml, so a removed key lingers on
        # disk; clear the old per-group model override explicitly.
        channel_overrides = null;
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
