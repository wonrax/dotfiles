{ pkgs, ... }:
{
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

      if [[ -a ~/.localrc ]]
      then
        source ~/.localrc
      fi
    '';
  };

}
