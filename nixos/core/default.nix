# Headless baseline for every personal NixOS host (peggy, wsl): nix itself,
# the user account, CLI tooling, tailscale and the shared Home Manager config.
# Anything that needs a display or real hardware goes in ../desktop.
{
  pkgs,
  user,
  ...
}:
{
  imports = [
    ./home-manager.nix
    ./nix-ld.nix
    ./services.nix
  ];

  nixpkgs.config.allowUnfree = true;
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    trusted-users = [ user.username ];
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  time.timeZone = "Asia/Ho_Chi_Minh";

  environment.systemPackages = with pkgs; [
    vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
    git
    curl
    wget
    unzip
    tmux
  ];

  virtualisation.docker.enable = true;

  users.users.${user.username} = {
    isNormalUser = true;
    description = user.fullname;
    extraGroups = [
      "wheel"
      "docker"
    ];
    packages = [ pkgs.lazydocker ];
  };

  # NixOS does not follow the XDG Base Directory Specification by default.
  # Tracking issue: https://github.com/NixOS/nixpkgs/issues/224525
  environment.variables = {
    XDG_CACHE_HOME = "$HOME/.cache";
    XDG_CONFIG_HOME = "$HOME/.config";
    XDG_DATA_HOME = "$HOME/.local/share";
    XDG_STATE_HOME = "$HOME/.local/state";
  };

  programs.nh = {
    enable = true;
    flake = "/home/${user.username}/.dotfiles";
  };
}
