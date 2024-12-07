{
  config,
  pkgs,
  lib,
  user,
  ...
}:

{
  # TODO please change the username & home directory to your own
  home.username = user.username;
  home.homeDirectory = "/home/${user.username}";

  # link the configuration file in current directory to the specified location in home directory
  # home.file.".config/i3/wallpaper.jpg".source = ./wallpaper.jpg;

  # link all files in `./scripts` to `~/.config/i3/scripts`
  home.file.".config/nvim" = {
    source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.dotfiles/.config/nvim";
    recursive = true; # link recursively
    executable = false; # make all files executable
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

  # Packages that should be installed to the user profile.
  home.packages = with pkgs; [
    # productivity
    neovim
    gh
    ripgrep

    # devel
    gcc
    nodejs_23
    rustup
    nixfmt-rfc-style

    # entertainment
    spotify

    # communication
    discord
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
