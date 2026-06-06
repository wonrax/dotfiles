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
let
  dotfilesDir = "${config.home.homeDirectory}/.dotfiles";
  agentSource = "${dotfilesDir}/.config/agents";
  mkAgentLink = path: {
    source = config.lib.file.mkOutOfStoreSymlink "${agentSource}/${path}";
    recursive = true;
    executable = false;
  };
  agentsMd = mkAgentLink "AGENTS.md";
  agentsSkills = mkAgentLink "skills";
  onePassPath =
    if pkgs.stdenv.isDarwin then
      "${config.home.homeDirectory}/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
    else
      "${config.home.homeDirectory}/.1password/agent.sock";
in
{
  home.username = user.username;
  home.homeDirectory =
    if pkgs.stdenv.isDarwin then "/Users/${user.username}" else "/home/${user.username}";

  # libsqlite3 path for nvim's smart-open (sqlite.lua via LuaJIT FFI). Wired up
  # in .config/nvim/lua/plugins/smart-open.lua via vim.g.sqlite_clib_path.
  home.sessionVariables.LIBSQLITE = "${pkgs.sqlite.out}/lib/libsqlite3${
    if pkgs.stdenv.isDarwin then ".dylib" else ".so"
  }";

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings."*" = {
      ForwardAgent = false;
      AddKeysToAgent = "no";
      Compression = false;
      ServerAliveInterval = 0;
      ServerAliveCountMax = 3;
      HashKnownHosts = false;
      UserKnownHostsFile = "~/.ssh/known_hosts";
      ControlMaster = "no";
      ControlPath = "~/.ssh/master-%r@%n:%p";
      ControlPersist = "no";
      IdentityAgent = "\"${onePassPath}\"";
    };
  };

  imports = [
    ./git.nix
    ./jujutsu.nix
    ./nushell.nix
    ./starship
    ./zoxide.nix
  ];

  xdg.configFile.nvim = {
    source = config.lib.file.mkOutOfStoreSymlink "${dotfilesDir}/.config/nvim";
    recursive = true;
    executable = false;
  };

  home.file.".tmux.conf" = {
    source = config.lib.file.mkOutOfStoreSymlink "${dotfilesDir}/.config/tmux/tmux.conf";
    recursive = true;
    executable = false;
  };

  home.file.".config/tmux/plugins/tpm" = {
    source = pkgs.fetchFromGitHub {
      owner = "tmux-plugins";
      repo = "tpm";
      rev = "v3.1.0";
      sha256 = "sha256-CeI9Wq6tHqV68woE11lIY4cLoNY8XWyXyMHTDmFKJKI=";
    };
  };

  xdg.configFile."ghostty/config".text = ''
    command = ${pkgs.nushell}/bin/nu

    # ghostty isn't in the terminfo database yet
    term = xterm-256color

    theme = light:Rose Pine Dawn,dark:Nightfox

    window-padding-x = 8
    window-padding-y = 4,8
    confirm-close-surface = false

    font-family = "Cascadia Code NF"
    font-feature = -calt
    font-thicken = true
    font-thicken-strength = 0
    adjust-box-thickness = 50%
    adjust-cell-height = 2
    macos-option-as-alt = true

    cursor-invert-fg-bg = false

    config-file = ?config.local

    custom-shader = ./cursor_blaze_no_trail.glsl
  '';

  xdg.configFile."ghostty/cursor_blaze_no_trail.glsl".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfilesDir}/.config/ghostty/cursor_blaze_no_trail.glsl";

  xdg.configFile."fish/completions/nix.fish".source = "${inputs.nix}/misc/fish/completion.fish";

  # Shared agent instructions + skills, fanned out to every tool's config dir.
  # Source lives in .config/agents/ (was .config/opencode/).
  xdg.configFile."opencode/skills" = agentsSkills;
  xdg.configFile."opencode/AGENTS.md" = agentsMd;
  home.file.".agents/skills" = agentsSkills;
  home.file.".codex/AGENTS.md" = agentsMd;
  home.file.".claude/skills" = agentsSkills;
  home.file.".claude/CLAUDE.md" = agentsMd;

  home.activation.assertDotfilesLocation =
    lib.hm.dag.entryBefore
      [
        "installPackages"
        "linkGeneration"
      ]
      ''
        if [ ! -f "${dotfilesDir}/flake.nix" ]; then
          echo "Please clone the dotfiles repository to ~/.dotfiles"
          exit 1
        fi
      '';

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
    source = config.lib.file.mkOutOfStoreSymlink "${dotfilesDir}/.config/zellij";
    recursive = true;
    executable = false;
  };

  # Packages that should be installed to the user profile.
  home.packages =
    with pkgs;
    [
      nix
      nix-output-monitor

      # .::= Productivity =::.
      neovim
      tmux
      gh
      bash
      # nushell is using fish for completions
      fish
      nh
      difftastic
      # unstablePkgs.opencode
      # unstablePkgs.codex

      htop
      btop
      tokei

      ripgrep
      bat
      eza
      fzf
      delta
      jq
      diffui

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
      nixfmt
      kdlfmt
      gnumake
      (pkgs.python312.withPackages (ppkgs: [
        # wanted by tmux window name
        ppkgs.libtmux
      ]))
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
