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
  # Upstream's daily/idle session reset is silently undone: the 4am expiry
  # watcher ends the session with end_reason='agent_close' (via agent
  # teardown), and on the next inbound message the #54878 stale-routing
  # self-heal resurrects exactly those rows with full history, bypassing the
  # reset policy. Carry PR #61743 (open, needs porting to the phased
  # get_or_create_session refactor) until it lands upstream — drop the patch
  # and this package override when it does. Build the patched gateway as a
  # PYTHONPATH overlay instead of importing from an applyPatches derivation:
  # importing the latter requires building it during evaluation, which fails
  # when an aarch64-darwin host evaluates the aarch64-linux deployment.
  hermesPkgs = inputs.hermes-agent.inputs.nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system};
  hermesSessionResetRecovery = hermesPkgs.runCommand "hermes-session-reset-recovery" {
    nativeBuildInputs = [ hermesPkgs.patch ];
    # Required: requiredPythonModules (used by the package's extraPythonPackages
    # handling to build PYTHONPATH) filters out any derivation without a
    # matching passthru.pythonModule — without this tag the overlay is
    # silently dropped and the patch never loads.
    passthru.pythonModule = hermesPkgs.python312;
  } ''
    site_packages="$out/${hermesPkgs.python312.sitePackages}"
    mkdir -p "$site_packages"
    cp -r ${inputs.hermes-agent}/gateway "$site_packages/gateway"
    chmod -R u+w "$site_packages/gateway"
    patch -d "$site_packages" -p1 < ${./61743-session-reset-recovery.patch}
  '';
  # Idle-triggered context compaction: carry upstream PR #55800 (open) —
  # compression.idle_compact_after_seconds compacts a resumed session's
  # accumulated history up front, before the first reply, when it comes back
  # after that much inactivity. Re-based onto this rev (the config-parse hunk
  # drifted); drop the patch and this overlay when it lands upstream. It works
  # on the gateway only because the agent-cache idle sweep defers eviction for
  # sessions with a finite reset policy (our daily/4am) until they expire, so
  # agent._last_activity_ts survives long gaps. A gateway restart clears that
  # state — the first resume after a deploy won't idle-compact (the size-based
  # hygiene pass still backstops).
  hermesIdleCompaction =
    hermesPkgs.runCommand "hermes-idle-compaction"
      {
        nativeBuildInputs = [ hermesPkgs.patch ];
        # See hermesSessionResetRecovery: the pythonModule tag is what keeps
        # requiredPythonModules from dropping this overlay off PYTHONPATH.
        passthru.pythonModule = hermesPkgs.python312;
      }
      ''
        site_packages="$out/${hermesPkgs.python312.sitePackages}"
        mkdir -p "$site_packages"
        cp -r ${inputs.hermes-agent}/agent "$site_packages/agent"
        chmod -R u+w "$site_packages/agent"
        patch -d "$site_packages" -p1 < ${./55800-idle-compaction.patch}
      '';
  hermesPatched =
    (hermesPkgs.callPackage "${inputs.hermes-agent}/nix/hermes-agent.nix" {
      inherit (inputs.hermes-agent.inputs) uv2nix pyproject-nix pyproject-build-systems;
      npm-lockfile-fix =
        inputs.hermes-agent.inputs.npm-lockfile-fix.packages.${pkgs.stdenv.hostPlatform.system}.default;
      rev = inputs.hermes-agent.rev or null;
    }).override
      {
        # Deliberately slimmer than upstream packages.default (the "full"
        # variant with every integration): only the groups actually used.
        extraDependencyGroups = [
          "firecrawl"
          "messaging"
          "voice"
        ];
        extraPythonPackages = [
          hermesSessionResetRecovery
          hermesIdleCompaction
        ];
      };

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
    services = [ "hermes-agent" ];
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
    serviceConfig.EnvironmentFile = "-${config.services.onepassword-secrets.secretPaths.hermesAgentEnv}";
    after = [ "opnix-secrets.service" ];
    wants = [ "opnix-secrets.service" ];
  };

  # SOUL.md (agent identity/personality) is read from $HERMES_HOME/SOUL.md
  # only — the module's `documents` option installs into the workspace, where
  # the identity loader never looks. Install it ourselves. Re-read at every
  # session start, so no service restart needed; the agent's own edits to it
  # are clobbered on deploy (intentional — nix is the source of truth).
  system.activationScripts.hermes-agent-soul =
    let
      cfg = config.services.hermes-agent;
    in
    lib.stringAfter [ "hermes-agent-setup" ] ''
      install -o ${cfg.user} -g ${cfg.group} -m 0660 ${./SOUL.md} ${cfg.stateDir}/.hermes/SOUL.md
    '';

  # Pin the flake registry's `nixpkgs` to the system's nixpkgs so the agent's
  # ephemeral `nix run nixpkgs#...` invocations resolve to the already-cached
  # rev instead of pulling unstable from the network on every fresh eval.
  nix.registry.nixpkgs.flake = inputs.nixpkgs;

  services.hermes-agent = {
    enable = true;
    addToSystemPackages = true;
    package = hermesPatched;

    environmentFiles = [ config.services.onepassword-secrets.secretPaths.hermesAgentEnv ];

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
        default = "gpt-5.6-terra";
      };

      agent.reasoning_effort = "low";

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

      session_reset = {
        mode = "daily";
        at_hour = 4;
      };

      # Consumed by the carried PR #55800 patch (hermesIdleCompaction above):
      # a session resumed after >=3h of inactivity compacts its stale history
      # first, then replies (the resuming message pays the summarization
      # latency; a 💤 status line shows while it runs). Skipped when the
      # context is already below the post-compaction target, so short threads
      # never pay for it. Overnight gaps are covered by the 4am reset instead.
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
