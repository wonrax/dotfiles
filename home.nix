{
  config,
  pkgs,
  lib,
  user,
  ...
}:
{
  home.username = user.username;
  home.homeDirectory = "/home/${user.username}";

  # TODO: find a way to assert that the dotfiles are cloned under ~/.dotfiles
  # otherwise the configuration will not work
  xdg.configFile.nvim = {
    source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.dotfiles/.config/nvim";
    recursive = true; # link recursively
    executable = false;
  };

  xdg.configFile.tmux = {
    source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.dotfiles/.config/tmux";
    recursive = true; # link recursively
    executable = false; # make all files executable
  };

  home.file.".tmux.conf" = {
    source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.dotfiles/.config/tmux/tmux.conf";
    recursive = true; # link recursively
    executable = false; # make all files executable
  };

  xdg.configFile.alacritty = {
    source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.dotfiles/.config/alacritty";
    recursive = true; # link recursively
    executable = false; # make all files executable
  };

  home.activation = {
    tmuxPluginManager = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      PATH="${pkgs.git}/bin:$PATH"
      # The .dotfiles absolute path where you cloned the repo
      DOTFILES="$HOME/.dotfiles"

      if [ ! -d "$HOME/.config/tmux/plugins/tpm" ]; then
        $DRY_RUN_CMD git clone https://github.com/tmux-plugins/tpm "$HOME/.config/tmux/plugins/tpm"
      fi

      if [[ ! -f "$DOTFILES/.config/alacritty/alacritty.toml" ]]; then
          echo "Creating a local alacritty config: alacritty.toml"
          cp $DOTFILES/.config/alacritty/alacritty.toml.template \
            $DOTFILES/.config/alacritty/alacritty.toml
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
    oh-my-zsh.plugins = [
      "zsh-autosuggestions"
    ];
    oh-my-zsh.package = pkgs.stdenv.mkDerivation rec {
      # Making a new oh-my-zsh derivation to include custom plugins
      name = "oh-my-zsh-customization-${version}";
      version = "2024-12-08";
      src = pkgs.fetchFromGitHub {
        owner = "ohmyzsh";
        repo = "ohmyzsh";
        rev = "69a6359f7cf8978d464573fb7b023ee3cd00181a";
        sha256 = "sha256-31wI3wFGQ9YhEo7XguLSTNY0rvOFa+/MoFwDAZIo7ZY";
      };

      zsh-autosuggestions = pkgs.fetchFromGitHub {
        owner = "zsh-users";
        repo = "zsh-autosuggestions";
        rev = "v0.7.1";
        sha256 = "sha256-vpTyYq9ZgfgdDsWzjxVAE7FZH4MALMNZIFyEOBLm5Qo";
      };

      zsh-syntax-highlighting = pkgs.fetchFromGitHub {
        owner = "zsh-users";
        repo = "zsh-syntax-highlighting";
        rev = "0.8.0";
        sha256 = "sha256-iJdWopZwHpSyYl5/FQXEW7gl/SrKaYDEtTH9cGP7iPo";
      };

      forgit = pkgs.fetchFromGitHub {
        owner = "wfxr";
        repo = "forgit";
        rev = "24.12.0";
        sha256 = "sha256-nFXouj2e0oyN9p4/pZlVa3vsSoJ3zJesHKY22V4eLKA";
      };

      zsh-vi-mode = pkgs.fetchFromGitHub {
        owner = "jeffreytse";
        repo = "zsh-vi-mode";
        rev = "v0.11.0";
        sha256 = "sha256-xbchXJTFWeABTwq6h4KWLh+EvydDrDzcY9AQVK65RS8";
      };

      dontBuild = true;
      installPhase = ''
        mkdir -p $out/share/oh-my-zsh/custom/plugins

        ln -s ${zsh-autosuggestions} $out/share/oh-my-zsh/custom/plugins/zsh-autosuggestions
        ln -s ${zsh-syntax-highlighting} $out/share/oh-my-zsh/custom/plugins/zsh-syntax-highlighting
        ln -s ${forgit} $out/share/oh-my-zsh/custom/plugins/forgit
        ln -s ${zsh-vi-mode} $out/share/oh-my-zsh/custom/plugins/zsh-vi-mode

        # This must be the last line because otherwise the the inner plugins
        # directory will be read-only and the plugin installation will fail
        cp -r $src/* $out/share/oh-my-zsh/
      '';
    };
    initExtra = ''
      ${builtins.readFile ./zshrc}
    '';
  };

  # Packages that should be installed to the user profile.
  home.packages = with pkgs; [
    # productivity
    alacritty
    neovim
    gh

    ripgrep
    bat
    eza
    fzf
    delta

    # devel
    gcc
    nodejs_23
    rustup
    nixfmt-rfc-style

    # entertainment
    spotify

    # communication
    discord

    # Fonts
    cascadia-code
  ];

  # TODO: what does this do?
  fonts.fontconfig.enableProfileFonts = true;

  # This value determines the home Manager release that your
  # configuration is compatible with. This helps avoid breakage
  # when a new home Manager release introduces backwards
  # incompatible changes.
  #
  # You can update home Manager without changing this value. See
  # the home Manager release notes for a list of state version
  # changes in each release.
  home.stateVersion = "24.11";

  # Let home Manager install and manage itself.
  programs.home-manager.enable = true;
}
