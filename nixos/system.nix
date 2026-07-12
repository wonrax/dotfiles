{
  inputs,
  user,
  pkgs,
  ...
}:
{
  nixpkgs.config.allowUnfree = true;
  nix.settings.trusted-users = [ user.username ];

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  environment.systemPackages = with pkgs; [
    vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
    git
    xclip
    unzip
    tmux
  ];

  virtualisation.docker.enable = true;

  users.users.${user.username} = {
    isNormalUser = true;
    description = user.fullname;
    extraGroups = [
      "networkmanager"
      "wheel"
      "i2c"
      "docker"
    ];

    packages = with pkgs; [
      google-chrome
      tailscale-systray
      jetbrains.datagrip
      vscode

      lazydocker

      # NOTE: These packages are NixOS specific because on macOS I'd like
      # for these programs to be able to update itself, which is only
      # possible if you install them the "normal" way.
      # - entertainment
      spotify
      plex-desktop
      # Pin VLC to 3.0.20 since 21 has an audio bug
      inputs.nixpkgs-vlc.legacyPackages.${pkgs.system}.vlc
      # - communication
      discord
      telegram-desktop

      # Vendored from nixpkgs PR #537215 until it lands; see the header of
      # pkgs/claude-desktop.nix for the quirks (keyring, FHS, no Cowork).
      (pkgs.callPackage ../pkgs/claude-desktop.nix { })

      alsa-utils # alsamixer

      ddcutil # brightness control

      nautilus # file manager

      librepods # airpods support
    ];
  };

  # Chromium/electron apps (claude-desktop in particular) persist login tokens
  # through libsecret, which needs an actual keyring daemon behind it — without
  # one they fall back to a plaintext store and Claude refuses to save sign-in.
  # PAM unlocks the keyring with the login password at SDDM login. 1Password is
  # unaffected: it brings its own vault and our ssh IdentityAgent is pinned to
  # its socket.
  services.gnome.gnome-keyring.enable = true;
  security.pam.services.sddm.enableGnomeKeyring = true;

  programs._1password.enable = true;
  programs._1password-gui = {
    enable = true;
    # Certain features, including CLI integration and system authentication
    # support, require enabling PolKit integration on some desktop environments
    # (e.g. Plasma).
    polkitPolicyOwners = [ user.username ];
  };

  programs.steam.enable = true;

  i18n.inputMethod = {
    enable = true;
    type = "fcitx5";
    fcitx5 = {
      addons = with pkgs; [ kdePackages.fcitx5-unikey ];
      waylandFrontend = true;
    };
  };

  # NixOS does not follow the XDG Base Directory Specification by default.
  # Tracking issue: https://github.com/NixOS/nixpkgs/issues/224525
  environment.variables = {
    XDG_CACHE_HOME = "$HOME/.cache";
    XDG_CONFIG_HOME = "$HOME/.config";
    XDG_DATA_HOME = "$HOME/.local/share";
    XDG_STATE_HOME = "$HOME/.local/state";
  };

  fonts.fontconfig.enable = true;

  programs.nh = {
    enable = true;
    flake = "/home/${user.username}/.dotfiles";
  };
}
