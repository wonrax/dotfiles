# Home Manager configuration that can be shared across machines and platforms
# including MacOS and Linux distributions other than NixOS. NixOS specific HM
# configurations should be put inside `nixos.nix`.
{
  config,
  pkgs,
  lib,
  user,
  ghostty,
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
    # TODO: this zshrc will source oh-my-zsh twice, once generated by home
    # manager and once in the dotfiles
    initExtra = ''
      source $HOME/.dotfiles/zshrc
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

  programs.git = {
    # TODO: set up git delta
    enable = true;
    userName = user.username;
    userEmail = user.email;
    extraConfig = {
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

  # Packages that should be installed to the user profile.
  home.packages =
    with pkgs;
    [
      # productivity
      alacritty
      neovim
      tmux
      gh
      bash

      htop
      btop
      tokei

      ripgrep
      bat
      eza
      fzf
      delta

      # devel
      pkg-config
      nodejs_23
      rustup
      nixfmt-rfc-style
      (pkgs.python312.withPackages (ppkgs: [
        # wanted by tmux window name
        ppkgs.libtmux
      ]))

      # Fonts
      cascadia-code
    ]
    ++ lib.optionals stdenv.isLinux [
      # Leave clang on MacOS alone, apparently crates like aws-lc-sys need
      # MacOS clang to build properly
      gcc

      # Ghostty has not been available for MacOS yet, related discussion:
      # https://github.com/ghostty-org/ghostty/discussions/2824
      ghostty.packages.${pkgs.stdenv.hostPlatform.system}.default
    ];

  # TODO: what does this do?
  fonts.fontconfig.enable = true;

  # NOTE: that you have to create a new shell session after changing these,
  # since these variables are being sourced only once per shell session.
  # TODO: Maybe consider using zsh variables instead.
  home.sessionVariables = {
    # Build time globally linked libraries, for runtime linking, use
    # LD_LIBRARY_PATH
    LIBRARY_PATH =
      "$LIBRARY_PATH:"
      + pkgs.lib.makeLibraryPath (
        with pkgs;
        [
          libiconv
        ]
      );
    PKG_CONFIG_PATH = "$PKG_CONFIG_PATH:${pkgs.openssl.dev}/lib/pkgconfig";
  };

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
