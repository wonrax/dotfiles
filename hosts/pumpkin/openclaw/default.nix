{
  inputs,
  ...
}:
let
  user = {
    username = "openclaw";
  };
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
      ];

      # https://github.com/openclaw/nix-openclaw/issues/50
      home.file.".openclaw/openclaw.json".force = true;
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
              allowFrom = [ 653083546 ];
              groups."*" = {
                requireMention = true;
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

            session = {
              reset = {
                mode = "idle";
                idleMinutes = 1440; # 24 hours
              };
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
