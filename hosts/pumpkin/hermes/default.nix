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
  sessionResetPolicyPlugin = pkgs.fetchFromGitHub {
    owner = "fastfinge";
    repo = "hermes-session-reset-policy";
    name = "hermes-session-reset-policy";
    rev = "493df020496d2782d3fe15308cc3b6672c2224c4";
    hash = "sha256-Ax//zlao53+YOwP/+v3AOYIH0R30U9ON7ixI3EjEEVI=";
  };

  # Hermes only supports a skills *denylist* (skills.disabled), so emulate a
  # whitelist by enumerating every bundled skill from the flake source at eval
  # time and disabling all but these. New upstream skills are therefore
  # disabled by default. Agent-created skills (in $HERMES_HOME/skills) are
  # unaffected. Skill names == their directory basenames (verified upstream).
  enabledSkills = [
    "arxiv"
    "github-auth"
    "github-issues"
    "github-pr-workflow"
    "github-repo-management"
    "youtube-content"
  ];
  hermesPkgs = inputs.hermes-agent.inputs.nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system};
  hermesBasePackage =
    (hermesPkgs.callPackage "${inputs.hermes-agent}/nix/hermes-agent.nix" {
      inherit (inputs.hermes-agent.inputs) uv2nix pyproject-nix pyproject-build-systems;
      npm-lockfile-fix =
        inputs.hermes-agent.inputs.npm-lockfile-fix.packages.${pkgs.stdenv.hostPlatform.system}.default;
      rev = inputs.hermes-agent.rev or null;
      version = "0.21.7";
      lastModified = inputs.hermes-agent.lastModified or null;
    }).override
      {
        # Deliberately slimmer than upstream packages.default (the "full"
        # variant with every integration): only the groups actually used.
        extraDependencyGroups = [
          "firecrawl"
          "messaging"
          "voice"
        ];
      };

  # Import the Nix package from the ordinary input, then patch Python at build
  # time; importing a patched derivation would require Linux builds during
  # evaluation on macOS. Hermes puts its source root first during bootstrap,
  # so retain the complete Python source and bind the wrappers to that root.
  hermesIdleCompaction =
    hermesPkgs.runCommand "hermes-idle-compaction-pr135759"
      {
        nativeBuildInputs = [ hermesPkgs.patch ];
      }
      ''
        cp -R ${hermesBasePackage.hermesNpmLib.pythonSrc} src
        chmod -R u+w src
        cd src
        mkdir -p tests/agent
        patch -p1 < ${./135759-idle-compaction.patch}
        mkdir -p $out/${hermesBasePackage.python.sitePackages}
        cp -R . $out/${hermesBasePackage.python.sitePackages}
        install -Dm644 tests/agent/test_idle_compaction_reference.py \
          $out/share/hermes-idle-compaction/test_idle_compaction_reference.py
      '';

  hermesPackage =
    (hermesBasePackage.override {
      extraPythonPackages = [ hermesIdleCompaction ];
    }).overrideAttrs
      (old: {
        postFixup = (old.postFixup or "") + ''
          for executable in "$out"/bin/*; do
            wrapProgram "$executable" --set HERMES_PYTHON_SRC_ROOT \
              ${hermesIdleCompaction}/${hermesBasePackage.python.sitePackages}
          done
        '';
      });

  bundledSkills =
    let
      skillsDir = "${inputs.hermes-agent}/skills";
      listSkills =
        dir:
        lib.flatten (
          lib.mapAttrsToList (
            name: type:
            if type != "directory" then
              [ ]
            else if builtins.pathExists "${dir}/${name}/SKILL.md" then
              [ name ]
            else
              listSkills "${dir}/${name}"
          ) (builtins.readDir dir)
        );
    in
    listSkills skillsDir;
in
{
  imports = [ inputs.hermes-agent.nixosModules.default ];

  # The op item must be an env file containing at least:
  #   TELEGRAM_BOT_TOKEN=123456:ABC...
  #   FIRECRAWL_API_KEY=fc-...  (web_search/web_extract backend)
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

  # Let the interactive user share HERMES_HOME with the gateway (the state dir
  # is group-writable) so the hermes CLI/TUI works from a normal shell
  users.users.${user.username}.extraGroups = [ config.services.hermes-agent.group ];

  # The hermes module copies environmentFiles into $HERMES_HOME/.env at
  # activation time, but opnix provisions secrets in a systemd service that
  # runs *after* activation — on first deploy the gateway came up with an
  # empty .env ("No messaging platforms enabled"). Feed the secret to the
  # process directly and order the gateway after opnix so a stale .env can
  # never leave it tokenless. ("-" prefix: don't fail if the file is missing.)
  systemd.services.hermes-agent = {
    restartTriggers = [ sessionResetPolicyPlugin ];
    serviceConfig.EnvironmentFile = "-${config.services.onepassword-secrets.secretPaths.hermesAgentEnv}";
    after = [ "opnix-secrets.service" ];
    wants = [ "opnix-secrets.service" ];
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
    package = hermesPackage;
    extraPlugins = [ sessionResetPolicyPlugin ];

    backend = {
      mode = "dashboard";
      waitFor = "interface";
      interfaceName = "tailscale0";
      port = 9119;
    };

    environmentFiles = [ config.services.onepassword-secrets.secretPaths.hermesAgentEnv ];

    # SOUL.md (agent identity) must live in $HERMES_HOME — `documents` installs
    # into the workspace, where the identity loader never looks. Re-read at
    # every session start, so no restart needed; the agent's own edits are
    # clobbered on deploy (intentional — nix is the source of truth). Replaces
    # the hand-rolled activation script we carried before upstream grew this
    # option.
    hermesHomeFiles."SOUL.md" = ./SOUL.md;

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

    extraPackages = with pkgs; [
      gh
      jujutsu
      # SOUL.md tells the agent to pull missing tools via `nix run/shell`;
      # the unit PATH is only this explicit list (no /run/current-system/sw/bin),
      # so nix itself has to be added here.
      config.nix.package
    ];

    mcpServers.affine = {
      url = "https://a.wrx.sh/api/workspaces/dace8f22-701f-4bb6-8c78-cbcb6d73cc42/mcp";
      headers.Authorization = "Bearer \${AFFINE_MCP_TOKEN}";
    };

    mcpServers.ticktick = {
      url = "https://mcp.ticktick.com";
      headers.Authorization = "Bearer \${TICKTICK_MCP_TOKEN}";
    };

    settings = {
      dashboard.public_url = dashboardUrl;
      plugins.enabled = [ "hermes-session-reset-policy" ];

      # The module deep-merges config.yaml, so explicitly clear any OAuth
      # mode left behind from an earlier TickTick configuration.
      mcp_servers.ticktick.auth = null;

      # ChatGPT-subscription auth (Codex OAuth), not the API: credentials come
      # from a one-time interactive `sudo -u hermes hermes auth add openai-codex`
      # device-code login, stored in $HERMES_HOME/auth.json (survives deploys;
      # refresh tokens rotate automatically). Codex models use bare slugs (no
      # openai/ prefix) and cap context at 272k vs 1.05M on the raw API.
      model = {
        provider = "openai-codex";
        default = "gpt-6.1-sol";
      };

      agent.reasoning_effort = "medium";

      # Backend for the web_search/web_extract tools. Auto-detect would pick
      # firecrawl anyway from FIRECRAWL_API_KEY (in the opnix envfile item),
      # but be explicit. The tools silently drop out of the model's schema
      # when the key is missing.
      web.backend = "firecrawl";

      # Stream replies into the chat via progressive message edits (plain text
      # while streaming, MarkdownV2 on the final edit). Gateway streaming is
      # controlled by this top-level key; display.streaming is CLI-only.
      streaming.enabled = true;

      display.platforms.telegram = {
        # Telegram's mobile-tuned platform default is "off"; "all" shows every
        # tool call with a short preview, accumulated into one edited bubble.
        tool_progress = "all";
        show_reasoning = false;
      };

      skills.disabled = lib.subtractLists enabledSkills bundledSkills;

      # Built-in memory replaces the mem0 plugin used with openclaw
      memory = {
        memory_enabled = true;
        user_profile_enabled = true;
      };

      # Core no longer applies this policy; the reset plugin checks the 4am
      # boundary on the next inbound message.
      session_reset = {
        mode = "daily";
        at_hour = 4;
      };

      # PR #135759 uses persisted transcript timestamps so idle detection
      # survives the watchdog reset, cache eviction, and gateway restarts.
      compression.idle_compact_after_seconds = 3 * 60 * 60;

      telegram = {
        dm_policy = "allowlist";
        allow_from = [ "653083546" ];
        group_policy = "allowlist";
        group_allow_from = [ "653083546" ];
        group_allowed_chats = [ telegramGroupId ];
        # Only the two forum topics the bot lives in; messages in other topics
        # of this group are ignored entirely (openclaw mention-gated them
        # instead, but they were never used). Topic 1 is the forum General
        # topic.
        allowed_topics = [
          "1"
          "3"
        ];
        require_mention = false;
        # Per-topic prompts replace openclaw's two agents (Life/Coding) bound
        # to these topics; keys are forum topic ids.
        channel_prompts = {
          "1" = ''
            This is the "Life" topic: personal assistant duties — planning,
            reminders, research, accountability and day-to-day life admin.
          '';
          "3" = ''
            This is the "Coding" topic: software engineering work. gh and jj
            (jujutsu) are available in the terminal; the user uses jj for
            version control, so prefer jj over git for mutating operations.
          '';
        };
      };
    };
  };
}
