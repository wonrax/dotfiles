# Graphical bare-metal desktop on top of ../core: GUI apps, 1Password app,
# keyring, input method, audio/keyboard hardware tweaks. The compositor
# modules (niri, dms, gnome) are imported here but each is gated behind its
# own enable option, set per host.
{
  inputs,
  user,
  pkgs,
  unstablePkgs,
  ...
}:
{
  imports = [
    ../core
    ./keyboard.nix
    ./services.nix
    ./niri.nix
    ./dms.nix
    ./gnome.nix
  ];

  environment.systemPackages = [ pkgs.xclip ];

  users.users.${user.username} = {
    extraGroups = [
      "networkmanager"
      "i2c"
    ];

    packages = with pkgs; [
      google-chrome
      tailscale-systray
      jetbrains.datagrip

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
      (pkgs.callPackage ../../pkgs/claude-desktop.nix { })

      # Vendored from nixpkgs PR #551713 until it lands; see the header of
      # pkgs/chatgpt-desktop.nix for the quirks (SIGILL asar patch, writable
      # plugin cache, keyring). Built from unstable so codex stays fresh.
      (unstablePkgs.callPackage ../../pkgs/chatgpt-desktop.nix { })

      alsa-utils # alsamixer

      ddcutil # brightness control

      nautilus # file manager

      librepods # airpods support

      unstablePkgs.ticktick
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

  fonts.fontconfig.enable = true;

  home-manager.users.${user.username} = {
    programs.ghostty.enable = true;
    programs.git.settings.gpg.ssh.program = "${pkgs._1password-gui}/bin/op-ssh-sign";
    programs.jujutsu.settings.signing.backends.ssh.program = "${pkgs._1password-gui}/bin/op-ssh-sign";
  };
}
