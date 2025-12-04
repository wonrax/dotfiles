{ pkgs, config, ... }:
{
  programs.nushell = {
    enable = true;
    environmentVariables = config.home.sessionVariables;
    configFile.text = ''
      # Convert PATH to a list if it's a string
      if ($env.PATH | describe) == "string" {
          $env.PATH = ($env.PATH | split row (char esep))
      }

      # TODO: find a way to get nix-profile paths instead of hardcoding them
      # HINT: how does programs.zsh do it?
      # Only run PATH setup once per top-level session
      if not ("DOTFILES_PATH_INITIALIZED" in $env) {
          $env.PATH = ([
              "~/.dotfiles/bin",
              "~/.cargo/bin",
              "~/.npm-packages/bin",
              "~/.orbstack/bin",
              "/usr/local/bin",
              "~/go/bin",
              "~/.local/bin"
              "/etc/profiles/per-user/wonrax/bin"

              # These two should have lower priority than the above since
              # sometimes I want to use external package managers like npm or
              # cargo because they provide more up-to-date versions of the
              # packages.
              "~/.nix-profile/bin",
              "/nix/var/nix/profiles/default/bin",
          ] | each { |p| path expand }) ++ $env.PATH

          # Set guard variable to prevent re-initialization
          $env.DOTFILES_PATH_INITIALIZED = true
      }

      # Aliases
      alias cat = bat
      alias la = ls -la
      alias l = ls
      alias cdd = cd ..
      alias gdfz = git-diff-fzf

      def gstfz [] {
        git status --short | awk '{print $2}' | fzf -m
      }

      $env.SHELL = "${pkgs.nushell}/bin/nu"
      $env.EDITOR = 'lean-nvim'
      $env.config.show_banner = false

      let zoxide_completer = {|spans|
        $spans | skip 1 | zoxide query -l ...$in | lines | where {|x| $x != $env.PWD}
      }

      let fish_completer = {|spans|
        fish --command $'complete "--do-complete=($spans | str join " ")"'
        | from tsv --flexible --noheaders --no-infer
        | rename value description
      }

      let external_completer = {|spans|
        let expanded_alias = scope aliases
        | where name == $spans.0
        | get -o 0.expansion

        let spans = if $expanded_alias != null {
          $spans
          | skip 1
          | prepend ($expanded_alias | split row ' ' | take 1)
        } else {
          $spans
        }

        match $spans.0 {
          z | zi | __zoxide_z | __zoxide_zi => $zoxide_completer
          _ => $fish_completer
        } | do $in $spans
      }

      $env.config = {
        highlight_resolved_externals: true # enables highlighting of external commands
        edit_mode: "vi"
        cursor_shape: {
          vi_insert: "line"
          vi_normal: "block"
        }
        keybindings: [
          {
            name: complete_history_hint_or_cycle_backward
            modifier: shift
            keycode: backtab
            mode: [ emacs, vi_insert, vi_normal ]
            event: {
              until: [
                { send: historyhintcomplete }
                { send: menuprevious }
                { send: left }
              ]
            }
          }
        ]
        completions: {
          external: {
            enable: true
            completer: $external_completer
          }
        }
      }

      $env.PROMPT_INDICATOR_VI_INSERT = { ||
        if $env.LAST_EXIT_CODE == 0 {
          $"(ansi blue): "
        } else {
          $"(ansi red): "
        }
      }

      $env.PROMPT_INDICATOR_VI_NORMAL = { ||
        if $env.LAST_EXIT_CODE == 0 {
          $"(ansi blue)> "
        } else {
          $"(ansi red)> "
        }
      }

      $env.PROMPT_COMMAND_RIGHT = { ||
        ""
      }

      # show a slightly different banner
      def show_banner [] {
        let ellie = [
          "     __  ,"
          " .--()°'.'"
          "'|, . ,'  "
          ' !_-(_\   '
        ]
        let s_mem = (sys mem)
        let s_ho = (sys host)
        print $"(ansi reset)(ansi green)($ellie.0)"
        print $"(ansi green)($ellie.1)  (ansi yellow) (ansi yellow_bold)Nushell (ansi reset)(ansi yellow)v(version | get version)(ansi reset)"
        print $"(ansi green)($ellie.2)  (ansi light_blue) (ansi light_blue_bold)RAM (ansi reset)(ansi light_blue)($s_mem.used) / ($s_mem.total)(ansi reset)"
        print $"(ansi green)($ellie.3)  (ansi light_purple)ﮫ (ansi light_purple_bold)Uptime (ansi reset)(ansi light_purple)($s_ho.uptime)(ansi reset)"
      }

      $env.config.hooks = {
        env_change: {
          PWD: [{|_, after| if $env.ZELLIJ? != null { ${pkgs.zellij}/bin/zellij action rename-tab ($after | path basename) } }]
        }
      }

      show_banner
    '';
  };

  home.packages = with pkgs; [ bat ];
}
