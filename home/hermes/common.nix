{
  inputs,
  pkgs,
  unstablePkgs,
  lib,
}:
let
  sessionResetPolicyPlugin = pkgs.fetchFromGitHub {
    owner = "fastfinge";
    repo = "hermes-session-reset-policy";
    name = "hermes-session-reset-policy";
    rev = "493df020496d2782d3fe15308cc3b6672c2224c4";
    hash = "sha256-Ax//zlao53+YOwP/+v3AOYIH0R30U9ON7ixI3EjEEVI=";
  };
  # Model provider that runs turns on the Claude subscription through the
  # `claude` CLI (in extraPackages). The plugin lives in a subdirectory of the
  # monorepo, and extraPlugins wants plugin.yaml at the package root.
  claudeSubscriptionPlugin =
    let
      src = pkgs.fetchFromGitHub {
        owner = "NousResearch";
        repo = "hermes-official-plugins";
        rev = "ab348e1d8d8691f56000875420bc3b29349a902b"; # 0.3.5
        hash = "sha256-kUd2NKPPfixSoYUDLYUtd5kQWrNCAqyuDl+SPlrfpTU=";
      };
    in
    pkgs.runCommand "claude-subscription-directsdk" { } ''
      cp -R ${src}/claude-subscription-directsdk $out
    '';
  # Hermes only supports a skills *denylist* (skills.disabled), so emulate a
  # whitelist by enumerating the bundled and optional catalogs at eval time
  # and disabling all but these. New upstream skills are therefore
  # disabled by default. Agent-created skills (in $HERMES_HOME/skills) are
  # unaffected. Declared skill names can differ from folder names.
  enabledSkills = [
    "arxiv"
    "github-auth"
    "github-issues"
    "github-pr-workflow"
    "github-repo-management"
    "youtube-content"
  ];
  # Retained from Pumpkin's .bundled_manifest after upstream catalog removals.
  legacyBundledSkills = [
    "merge-reconciler"
    "touchdesigner-mcp"
    "github-code-review"
    "github-issue-to-pr"
    "nano-pdf"
    "ocr-and-documents"
    "session-librarian"
    "plan"
    "github/codebase-inspection"
    "research/blocked-page-recovery"
    "web/blocked-page-recovery"
    "software-development/codebase-inspection"
    "autonomous-ai-agents/computer-use"
    "software-development/dogfood"
  ];
  hermesPkgs = inputs.hermes-agent.inputs.nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system};
  pmPackages = lib.filterAttrs (_: lib.isDerivation) (
    hermesPkgs.callPackage "${inputs.hermes-agent}/nix/pm-packages.nix" { }
  );
  hermesBasePackage =
    (hermesPkgs.callPackage "${inputs.hermes-agent}/nix/hermes-agent.nix" {
      # NousResearch/hermes-agent#150967 (open): pnpm's macOS clone probe
      # leaves an empty v11/links in the store, so the pnpm-deps hash only
      # matches on Linux. Drop once that lands in a tag.
      callPackage = lib.callPackageWith (
        hermesPkgs
        // {
          fetchPnpmDeps =
            args:
            hermesPkgs.fetchPnpmDeps (
              args
              // {
                preFixup = (args.preFixup or "") + ''
                  rmdir "$storePath/v11/links" 2>/dev/null || true
                '';
              }
            );
        }
      );
      inherit (inputs.hermes-agent.inputs) uv2nix pyproject-nix pyproject-build-systems;
      inherit pmPackages;
      rev = inputs.hermes-agent.rev or null;
      version = "0.23.1";
      lastModified = inputs.hermes-agent.lastModified or null;
    }).override
      {
        # Deliberately slimmer than upstream packages.default (the "full"
        # variant with every integration): only the groups actually used.
        extraDependencyGroups = [
          "firecrawl"
          "messaging"
          "voice"
        ]
        ++ lib.optional pkgs.stdenv.isDarwin "computer-use";
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
        patch -p1 < ${../../hosts/pumpkin/hermes/135759-idle-compaction.patch}
        # Idle floor is otherwise threshold × target_ratio (≥75K at 0.75 × 1M).
        patch -p1 < ${./idle-compact-min-tokens.patch}
        patch -p1 < ${./a2a-owner-peers.patch}
        # Upstream tells the agent to keep memory small and drop anything
        # stale within a week, which produced a pointer-only USER.md.
        patch -p1 < ${./memory-profile-prompts.patch}
        patch -p1 < ${./memory-matched-entry-schema.patch}
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
          cp -RL "$out/share/hermes-agent/plugins" "$out/share/hermes-agent/plugins-patched"
          chmod -R u+w "$out/share/hermes-agent/plugins-patched"
          for module in __init__.py security.py adapter.py tools.py; do
            cp ${hermesIdleCompaction}/${hermesBasePackage.python.sitePackages}/plugins/platforms/a2a/"$module" \
              "$out/share/hermes-agent/plugins-patched/platforms/a2a/$module"
          done
          rm "$out/share/hermes-agent/plugins"
          mv "$out/share/hermes-agent/plugins-patched" "$out/share/hermes-agent/plugins"
          for executable in "$out"/bin/*; do
            wrapProgram "$executable" --set HERMES_PYTHON_SRC_ROOT \
              ${hermesIdleCompaction}/${hermesBasePackage.python.sitePackages} \
              --prefix PYTHONPATH : ${hermesIdleCompaction}/${hermesBasePackage.python.sitePackages}
          done
        '';
      });

  bundledSkills =
    let
      skillNames =
        prefix: dir: name:
        let
          text = lib.replaceStrings [ "\r\n" ] [ "\n" ] (builtins.readFile "${dir}/${name}/SKILL.md");
          frontmatter = lib.splitString "\n" (
            builtins.head (lib.splitString "\n---" (lib.removePrefix "---\n" text))
          );
          nameLine = lib.findFirst (line: lib.hasPrefix "name:" line) "name: ${name}" frontmatter;
          declaredName = lib.strings.trim (lib.removePrefix "name:" nameLine);
          unquotedName = lib.removeSuffix "'" (
            lib.removePrefix "'" (lib.removeSuffix "\"" (lib.removePrefix "\"" declaredName))
          );
        in
        [
          name
          unquotedName
        ]
        ++ lib.optional (!(lib.elem unquotedName enabledSkills)) "${prefix}${name}";
      listSkills =
        prefix: dir:
        lib.flatten (
          lib.mapAttrsToList (
            name: type:
            if type != "directory" then
              [ ]
            else if builtins.pathExists "${dir}/${name}/SKILL.md" then
              skillNames prefix dir name
            else
              listSkills "${prefix}${name}/" "${dir}/${name}"
          ) (builtins.readDir dir)
        );
    in
    lib.unique (
      listSkills "" "${inputs.hermes-agent}/skills"
      ++ listSkills "" "${inputs.hermes-agent}/optional-skills"
      ++ legacyBundledSkills
    );
in
rec {
  package = hermesPackage;
  extraPackages = with pkgs; [
    gh
    jujutsu
    nodejs
    nix
    unstablePkgs.claude-code
  ];
  extraPlugins = [
    sessionResetPolicyPlugin
    claudeSubscriptionPlugin
  ];
  inherit sessionResetPolicyPlugin claudeSubscriptionPlugin;
  mcpServers = {
    affine = {
      url = "https://a.wrx.sh/api/workspaces/dace8f22-701f-4bb6-8c78-cbcb6d73cc42/mcp";
      headers.Authorization = "Bearer \${AFFINE_MCP_TOKEN}";
    };

    ticktick = {
      url = "https://mcp.ticktick.com";
      headers.Authorization = "Bearer \${TICKTICK_MCP_TOKEN}";
    };

    moneylover = {
      # Build pinned dependencies and the auth-recovery patch at deploy time.
      command = "${import ./moneylover-mcp.nix { inherit pkgs; }}/bin/moneylover-mcp";
      args = [ ];
      env = {
        EMAIL = "\${MONEYLOVER_EMAIL}";
        PASSWORD = "\${MONEYLOVER_PASSWORD}";
        MONEYLOVER_MCP_DISABLE_ENV_FILE = "1";
      };
    };

  };
  settings = {
    telegram = {
      dm_policy = "allowlist";
      allow_from = [ "653083546" ];
      group_policy = "allowlist";
      group_allow_from = [ "653083546" ];
      group_allowed_chats = [ "-1003508166716" ];
      require_mention = false;
    };
    plugins.enabled = [
      "hermes-session-reset-policy"
      "a2a-platform"
    ];
    platform_toolsets = {
      cli = [
        "hermes-cli"
        "a2a"
      ]
      ++ builtins.attrNames mcpServers;
      telegram = [
        "hermes-telegram"
        "a2a"
      ]
      ++ builtins.attrNames mcpServers;
      a2a = [
        "hermes-cli"
        "a2a"
      ]
      ++ builtins.attrNames mcpServers;
    };
    # The module deep-merges config.yaml, so explicitly clear any OAuth
    # mode left behind from an earlier TickTick configuration.
    mcp_servers.ticktick.auth = null;

    # Claude-subscription auth through the claude-subscription-directsdk
    # plugin, which drives the `claude` CLI. The CLI authenticates from
    # CLAUDE_CODE_OAUTH_TOKEN (a `claude setup-token` token) in the gateway's
    # environment; the plugin passes it through and strips only ANTHROPIC_*
    # API credentials. The openai-codex OAuth login in auth.json stays usable
    # via /model.
    model = {
      provider = "claude-subscription-directsdk-experimental";
      default = "opus";
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
      # Defaults are 2200/1375 (~800/~500 tokens). Both files ride in every
      # system prompt in full, so this is a per-session token cost.
      memory_char_limit = 8000;
      user_char_limit = 24000;
    };

    # Core no longer applies this policy; the reset plugin checks the 4am
    # boundary on the next inbound message.
    session_reset = {
      mode = "daily";
      at_hour = 4;
    };

    # PR #135759 uses persisted transcript timestamps so idle detection
    # survives the watchdog reset, cache eviction, and gateway restarts.
    compression = {
      threshold = 0.75;
      idle_compact_after_seconds = 60 * 60;
      idle_compact_min_tokens = 50000;
    };

  };
}
