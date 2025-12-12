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

  imports = [
    ./git.nix
    ./jujutsu.nix
    ./nushell.nix
    ./starship
    ./zoxide.nix
  ];

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

  xdg.configFile."fish/completions/nix.fish" = {
    source = "${inputs.nix}/misc/fish/completion.fish";
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
  };

  programs.ghostty = {
    enable = pkgs.stdenv.isLinux; # ghostty package is currently marked as broken on MacOS
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
      unstablePkgs.neovim
      tmux
      gh
      bash
      # nushell is using fish for completions
      fish
      nh
      difftastic
      unstablePkgs.opencode

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
      deno
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
    ];

  # Let home Manager install and manage itself.
  programs.home-manager.enable = true;
}
