{
  inputs,
  ...
}:
let
  user = {
    username = "openclaw";
  };
  codingWorkspace = "/home/${user.username}/.openclaw/workspace-coding";
  codingAgentDir = "/home/${user.username}/.openclaw/agents/coding/agent";
  lifeTopicPeerId = "-1003508166716:topic:1";
  codingTopicPeerId = "-1003508166716:topic:3";
in
{
  nixpkgs.overlays = [ inputs.nix-openclaw.overlays.default ];

  users.groups.${user.username} = { };
  users.users.${user.username} = {
    isNormalUser = true;
    group = user.username;
    linger = true;
  };

  home-manager.users.${user.username} =
    {
      pkgs,
      lib,
      ...
    }:
    {
      imports = [
        inputs.nix-openclaw.homeManagerModules.openclaw
      ];
      home.stateVersion = "25.11";
      home.packages = with pkgs; [
        openclaw

        gh
        jujutsu
      ];

      # https://github.com/openclaw/nix-openclaw/issues/50
      home.file.".openclaw/openclaw.json".force = true;
      home.file.".openclaw/workspace-coding/AGENTS.md".source = ../../../.config/opencode/AGENTS.md;
      home.file.".openclaw/workspace-coding/SOUL.md".source = ./documents/SOUL.md;
      home.file.".openclaw/workspace-coding/USER.md".source = ./documents/USER.md;
      home.file.".openclaw/workspace-coding/IDENTITY.md".source = ./documents/IDENTITY.md;
      home.file.".openclaw/workspace-coding/TOOLS.md".source = ./documents/TOOLS.md;
      programs.openclaw = {
        toolNames = [ ]; # disable all extended tools
        bundledPlugins = {
          summarize.enable = false; # Summarize web pages, PDFs, videos
          peekaboo.enable = false; # Take screenshots
          poltergeist.enable = false; # Control your macOS UI
          sag.enable = false; # Text-to-speech
          camsnap.enable = false; # Camera snapshots
          gogcli.enable = false; # Google Calendar
          goplaces.enable = false; # Google Places API
          bird.enable = false; # Twitter/X
          sonoscli.enable = false; # Sonos control
          imsg.enable = false; # iMessage
        };
        config = { };

        # REPLACE: path to your managed documents directory
        documents = ./documents;
        instances.default = {
          enable = true;
          systemd.enable = true;
          config = {
            gateway = {
              mode = "local";
              bind = "lan";
              controlUi = {
                allowedOrigins = [ "http://pumpkin:18789" ];
                dangerouslyDisableDeviceAuth = true;
              };
            };
            discovery = {
              mdns.mode = "off";
            };

            channels.telegram = {
              tokenFile = "/home/${user.username}/.secrets/telegram-openclaw-token";
              dmPolicy = "allowlist";
              allowFrom = [ 653083546 ];
              groupPolicy = "allowlist";
              groupAllowFrom = [ 653083546 ];
              groups."-1003508166716" = {
                systemPrompt = ''
                  On the first substantive turn of each new session in this group, ensure the workspace instruction files have been loaded.

                  If any of these files were not injected, were marked missing, or have not yet been read in this session, read them manually with fs tools from the current workspace root before giving the first real answer:
                  - AGENTS.md
                  - SOUL.md
                  - USER.md
                  - IDENTITY.md
                  - TOOLS.md

                  Do not rely on workspace bootstrap presence markers for these files, because they may appear missing even when they are readable.

                  Only do this once per new session/topic unless the user asks to refresh instructions.
                '';
                # Restrict always-on behavior to the intended forum topics.
                # Other topics in this group stay mention-gated.
                requireMention = true;
                topics."1".requireMention = false;
                topics."3".requireMention = false;
              };
            };

            tools.allow = [
              "group:messaging"
              "group:web"
              "group:fs"
              "group:memory"
              "group:runtime"

              # five mem0 tools
              "memory_search"
              "memory_list"
              "memory_store"
              "memory_get"
              "memory_forget"

              "cron"
            ];

            session.resetByType.thread = {
              mode = "daily";
              atHour = 4;
            };

            agents.defaults = {
              model = {
                primary = "openai-codex/gpt-5.4";
              };

              # disable tool call pruning because the instruction md files are
              # acquired via tools, and we want to keep those
              contextPruning = {
                mode = "off";
              };

              heartbeat = {
                every = "0m"; # 0m disables
                model = "openai-codex/gpt-5.1-codex-mini";
                session = "main";
                to = "653083546";
                directPolicy = "allow"; # allow (default) | block
                target = "telegram"; # default: none | options: last | whatsapp | telegram | discord | ...
              };
            };
            agents.list = [
              {
                id = "main";
                default = true;
                name = "Life";
                workspace = "/home/${user.username}/.openclaw/workspace";
                agentDir = "/home/${user.username}/.openclaw/agents/main/agent";
              }
              {
                id = "coding";
                name = "Coding";
                workspace = codingWorkspace;
                agentDir = codingAgentDir;
              }
            ];
            bindings = [
              {
                agentId = "coding";
                match = {
                  channel = "telegram";
                  peer = {
                    kind = "group";
                    id = codingTopicPeerId;
                  };
                };
              }
              {
                agentId = "main";
                match = {
                  channel = "telegram";
                  peer = {
                    kind = "group";
                    id = lifeTopicPeerId;
                  };
                };
              }
            ];
            auth = {
              profiles = {
                # run `openclaw onboard --auth-choice openai-codex`
                # to get the oauth token
                "openai-codex:default" = {
                  provider = "openai-codex";
                  mode = "oauth";
                };
              };
              order = {
                openai-codex = [ "openai-codex:default" ];
              };
            };
            plugins = {
              enabled = true;
              # allow = [ "openclaw-mem0" ];
              entries.openclaw-mem0 = {
                enabled = true;
                config = {
                  userId = "1";
                  topK = 10;

                  # turn recall off because agent already has memory tools and
                  # we don't want overlapping/duplicate memory results
                  autoRecall = false;
                  autoCapture = true;
                };
              };
            };
          };
        };
      };

      systemd.user.services.openclaw-gateway = {
        Service = {
          StandardOutput = lib.mkForce "journal";
          StandardError = lib.mkForce "journal";
        };
        Install.WantedBy = [ "default.target" ];
      };

      home.activation.seedCodingAgentAuth = lib.hm.dag.entryAfter [ "openclawConfigFiles" ] ''
        src="/home/${user.username}/.openclaw/agents/main/agent/auth-profiles.json"
        dst_dir="${codingAgentDir}"
        dst="$dst_dir/auth-profiles.json"

        mkdir -p "$dst_dir"
        if [ -r "$src" ] && [ ! -e "$dst" ]; then
          install -m 600 "$src" "$dst"
        fi
      '';

      home.activation.installOpenclawMem0Plugin =
        lib.hm.dag.entryAfter
          [ "openclawPluginGuard" "linkGeneration" "openclawConfigFiles" "reloadSystemd" ]
          ''
            export PATH="${
              lib.makeBinPath [
                pkgs.nodejs
                pkgs.openclaw
              ]
            }:$PATH"
            mem0_api_key_file="/home/${user.username}/.secrets/mem0-api-key"
            if [ -r "$mem0_api_key_file" ]; then
              mem0_api_key="$(cat "$mem0_api_key_file")"
              if openclaw config set plugins.entries.openclaw-mem0.config.apiKey "$mem0_api_key"; then
                rm -rf /home/${user.username}/.openclaw/extensions/openclaw-mem0
                if openclaw plugins install @mem0/openclaw-mem0; then
                  openclaw plugins enable openclaw-mem0
                  openclaw config set plugins.allow '[ "openclaw-mem0" ]' --strict-json
                  echo "configured apiKey and installed openclaw plugin @mem0/openclaw-mem0"
                else
                  echo "configured apiKey, but failed to install @mem0/openclaw-mem0" >&2
                fi
              else
                echo "failed to configure mem0 api key" >&2
              fi
            else
              echo "missing $mem0_api_key_file; skipping @mem0/openclaw-mem0 setup" >&2
            fi
          '';
    };
}
