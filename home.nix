# Home Manager configuration that can be shared across machines and platforms
# including MacOS and Linux distributions other than NixOS. NixOS specific HM
# configurations should be put inside `nixos.nix`.
{
  config,
  pkgs,
  lib,
  user,
  unstablePkgs,
  inputs,
  ...
}:
{
  home.username = user.username;
  home.homeDirectory =
    if pkgs.stdenv.isDarwin then "/Users/${user.username}" else "/home/${user.username}";

  xdg.configFile.nvim = {
    source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.dotfiles/.config/nvim";
    recursive = true; # link recursively
    executable = false;
  };

  home.file.".tmux.conf" = {
    source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.dotfiles/.config/tmux/tmux.conf";
    recursive = true; # link recursively
    executable = false; # make all files executable
  };

  home.file.".config/tmux/plugins/tpm" = {
    source = pkgs.fetchFromGitHub {
      owner = "tmux-plugins";
      repo = "tpm";
      rev = "v3.1.0";
      sha256 = "sha256-CeI9Wq6tHqV68woE11lIY4cLoNY8XWyXyMHTDmFKJKI=";
    };
  };

  xdg.configFile.ghostty = {
    source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.dotfiles/.config/ghostty";
    recursive = true; # link recursively
    executable = false;
  };

  home.activation = {
    # Make sure that the dotfiles are cloned in the correct location so that
    # the configuration can be linked and binaries are available
    # TODO: is there a better way to do this?
    assertDotfilesLocation =
      lib.hm.dag.entryBefore
        [
          "installPackages"
          "linkGeneration"
        ]
        ''
          if [ ! -f "$HOME/.dotfiles/flake.nix" ]; then
            echo "Please clone the dotfiles repository to ~/.dotfiles"
            exit 1
          fi
        '';
    # TODO: disable font smoothing on macos: defaults write org.alacritty AppleFontSmoothing -int 0
    tmuxPluginManager = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      PATH="${pkgs.git}/bin:$PATH"
      # The .dotfiles absolute path where you cloned the repo
      DOTFILES="$HOME/.dotfiles"

      if [[ ! -f "$DOTFILES/.config/alacritty/alacritty.local.toml" ]]; then
          echo "Creating a local alacritty config: alacritty.toml"
          cp $DOTFILES/.config/alacritty/alacritty.toml.template \
            $DOTFILES/.config/alacritty/alacritty.local.toml
      fi
    '';
  };

  # encode the file content in nix configuration file directly
  # home.file.".xxx".text = ''
  #     xxx
  # '';

  # set cursor size and dpi for 4k monitor
  # xresources.properties = {
  #   "Xcursor.size" = 16;
  #   "Xft.dpi" = 172;
  # };

  # allowUnfree is also enabled for nixos configuration but we need to enable
  # it here as well since home-manager.useUserPackages = true making it a user
  # configuration. If you want the nixos configuration to also affect
  # home-manager configuration, you can set home-manager.useGlobalPkgs = true
  # in nixos configuration. Explanation:
  # https://discourse.nixos.org/t/home-manager-useuserpackages-useglobalpkgs-settings/
  nixpkgs.config.allowUnfree = true;

  programs.zsh = {
    enable = true;
    oh-my-zsh.enable = true;
    oh-my-zsh.theme = "refined";
    oh-my-zsh.plugins = [
      "git"
      "tmux"
      "npm"
      "z"
    ];
    plugins = [
      {
        name = "zsh-autosuggestions";
        src = pkgs.fetchFromGitHub {
          owner = "zsh-users";
          repo = "zsh-autosuggestions";
          rev = "v0.7.1";
          sha256 = "sha256-vpTyYq9ZgfgdDsWzjxVAE7FZH4MALMNZIFyEOBLm5Qo";
        };
      }
      {
        name = "zsh-syntax-highlighting";
        src = pkgs.fetchFromGitHub {
          owner = "zsh-users";
          repo = "zsh-syntax-highlighting";
          rev = "0.8.0";
          sha256 = "sha256-iJdWopZwHpSyYl5/FQXEW7gl/SrKaYDEtTH9cGP7iPo";
        };
      }
      {
        name = "zsh-vi-mode";
        src = pkgs.fetchFromGitHub {
          owner = "jeffreytse";
          repo = "zsh-vi-mode";
          rev = "v0.11.0";
          sha256 = "sha256-xbchXJTFWeABTwq6h4KWLh+EvydDrDzcY9AQVK65RS8";
        };
      }
    ];
    initContent = ''
      # Automatic rename tmux window after changing dir
      # https://github.com/ofirgall/tmux-window-name?tab=readme-ov-file#automatic-rename-after-changing-dir
      tmux-window-name() {
        # Only run the command if we are in a tmux session
        if [ -n "$TMUX" ] || return
        ($TMUX_PLUGIN_MANAGER_PATH/tmux-window-name/scripts/rename_session_windows.py &)
      }

      add-zsh-hook chpwd tmux-window-name

      bindkey '^I'   complete-word       # tab          | complete
      bindkey '^[[Z' autosuggest-accept  # shift + tab  | autosuggest
      zvm_bindkey viins '^I'   complete-word
      zvm_bindkey viins '^[[Z' autosuggest-accept

      ZSH_AUTOSUGGEST_STRATEGY=(history completion)
      ZSH_AUTOSUGGEST_CLEAR_WIDGETS+=(buffer-empty bracketed-paste accept-line push-line-or-edit)
      ZSH_AUTOSUGGEST_USE_ASYNC=true

      export DOTFILES="$HOME/.dotfiles"
      # TODO: consider moving these to zsh.envExtra
      export SYSTEMD_EDITOR=lean-nvim
      export EDITOR=lean-nvim
      export PATH=$PATH:$DOTFILES/bin
      export PATH=$PATH:~/.cargo/bin
      # Global npm packages
      export PATH=$PATH:$HOME/.npm-packages/bin
      # diffstatic
      export DFT_DISPLAY=inline

      source $DOTFILES/alias

      if [[ -a ~/.localrc ]]
      then
        source ~/.localrc
      fi
    '';
  };

  programs.alacritty = {
    enable = true;
    settings = {
      general.import = [
        "~/.dotfiles/.config/alacritty/alacritty.base.toml"
        "~/.dotfiles/.config/alacritty/alacritty.local.toml"
      ];
      terminal.shell = "${pkgs.zsh}/bin/zsh";
    };
  };

  programs.ghostty = {
    enable = pkgs.stdenv.isLinux; # ghostty package is currently marked as broken on MacOS
  };

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

      source ~/.dotfiles/alias

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
        | get -i 0.expansion

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
                { send: menuleft }
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
          PWD: [{|_, after| if $env.ZELLIJ? != null { ${pkgs.zellij}/bin/zellij action rename-tab $after } }]
        }
      }

      show_banner
    '';
  };

  programs.starship = {
    enable = true;
    enableNushellIntegration = true;
    settings = {
      # https://starship.rs/presets/pure-preset
      format = lib.replaceStrings [ "\n" ] [ "" ] ''
        $username
        $hostname
        $directory
        $cmd_duration
        $python
        $character'';
      directory.style = "bold cyan";
      character = {
        format = "$symbol";
        success_symbol = "[>](blue)";
        error_symbol = "[>](red)";
      };
      cmd_duration = {
        format = "[$duration]($style) ";
        style = "yellow";
      };
      python = {
        format = "[$virtualenv]($style) ";
        style = "bright-black";
      };
    };
  };

  programs.zoxide = {
    enable = true;
    enableNushellIntegration = true;
  };

  programs.git = {
    enable = true;
    userName = user.username;
    userEmail = user.email;
    extraConfig = {
      user.signingKey = user.ssh-pub-key;

      pull.rebase = false;
      pull.ff = true;

      merge.conflictStyle = "diff3";

      # enable gpg signing
      commit.gpgsign = true;
      gpg.format = "ssh";

      # TODO: what are all these difftool doing with each other?

      diff = {
        colorMoved = "default";
        tool = "${pkgs.difftastic}/bin/difft";
      };

      difftool = {
        prompt = false;
        difftastic = {
          cmd = "${pkgs.difftastic}/bin/difft '$LOCAL' '$REMOTE'";
        };
      };

      pager.difftool = true;
      alias.dft = "difftool";

      core.pager = "${pkgs.delta}/bin/delta";
      interactive.diffFilter = "${pkgs.delta}/bin/delta --color-only";
      delta = {
        navigate = true;
        line-numbers = true;
      };
    };
  };

  programs.jujutsu = {
    enable = true;
    settings = {
      signing = {
        behavior = "own";
        backend = "ssh";
        key = user.ssh-pub-key;
      };
      # lazily signing only on push
      git.sign-on-push = true;
      user = {
        name = user.username;
        email = user.email;
      };
      aliases.difft = [
        "diff"
        "--tool"
        "difft"
      ];
      merge-tools = {
        difft = {
          program = "${pkgs.difftastic}/bin/difft";
          diff-args = [
            "--color=always"
            "--display"
            "inline"
            "$left"
            "$right"
          ];
        };
      };
      ui.diff.format = "git"; # so that delta can parse it
      ui.pager = [
        "${pkgs.delta}/bin/delta"
        "--true-color"
        "always"
        "--hunk-header-decoration-style"
        "blue"
        "--width=-2" # use terminal width minus 2
        "--file-style=bold"
        "--file-decoration-style"
        "omit"
        "--line-numbers-right-format"
        "{np} "
        "--line-numbers-left-format"
        "{nm} "
      ];
    };
  };

  programs.atuin = {
    enable = true;
    enableNushellIntegration = true;
  };

  programs.zellij = {
    enable = true;
  };

  xdg.configFile.zellij = {
    source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.dotfiles/.config/zellij";
    recursive = true; # link recursively
    executable = false;
  };

  # Packages that should be installed to the user profile.
  home.packages =
    with pkgs;
    [
      nix

      # .::= Productivity =::.
      alacritty
      unstablePkgs.neovim
      tmux
      gh
      bash
      # nushell is using fish for completions
      fish
      nh
      difftastic

      htop
      btop
      tokei

      ripgrep
      bat
      eza
      fzf
      delta
      jq

      # .::= Devel =::.

      # pkg-config libraries (will be automatically included in pkg-config path)
      pkg-config
      openssl

      # Downgraded from nodejs_23 because for some reason I had to build from
      # source which requires a lot of time and memory (my machine froze every
      # time and had to add swap in order for it to build).
      nodejs_22
      rustup
      go
      uv
      nixfmt-rfc-style
      kdlfmt
      gnumake
      (pkgs.python312.withPackages (ppkgs: [
        # wanted by tmux window name
        ppkgs.libtmux
      ]))
      (haskellPackages.ghcWithPackages (
        hspkgs: with hspkgs; [
          cabal-install
          haskell-language-server
        ]
      ))
      gnupg

      # .::= Fonts =::.
      cascadia-code
    ]
    ++ lib.optionals stdenv.isLinux [
      # Leave clang on MacOS alone, apparently crates like aws-lc-sys need
      # MacOS clang to build properly
      gcc

      unstablePkgs.opencode
    ];

  # This value determines the home Manager release that your
  # configuration is compatible with. This helps avoid breakage
  # when a new home Manager release introduces backwards
  # incompatible changes.
  #
  # You can update home Manager without changing this value. See
  # the home Manager release notes for a list of state version
  # changes in each release.
  # FIXME: move this to host specific config instead of shared one
  home.stateVersion = "24.11";

  # Let home Manager install and manage itself.
  programs.home-manager.enable = true;
}
