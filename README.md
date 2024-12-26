# wonrax's dotfiles

This repository began as a collection of dotfiles but has evolved into a
comprehensive Nix configuration for my NixOS system and Home Manager setup,
supporting both MacOS and NixOS environments. While the legacy installation
script method remains available for situations where NixOS or Home Manager is
not desired, it is no longer actively maintained.

- Clone this repository to `~/.dotfiles`
- Subsequent commands are expected to be run from the repository root

## NixOS

Simply run `nixos-rebuild` to apply the configuration including Home Manager
configuration.

```shell
sudo nixos-rebuild switch --flake .
```

## Home Manager standalone

If you want to use only the Home Manager configuration, or if you're on macOS,
you can use Home Manager standalone. This requires Nix to be installed - the
[Determinate Nix
Installer](https://github.com/DeterminateSystems/nix-installer) is recommended.

When applying the Home Manager configuration for the first time, you'll need to
install Home Manager itself. Run the following commands in a temporary
nix-shell to install Home Manager:

```shell
nix-channel --add https://github.com/nix-community/home-manager/archive/release-24.11.tar.gz home-manager
nix-channel --update
nix-shell -p home-manager --run "home-manager switch --flake ."
```

After the initial installation, subsequent updates can be applied with the
following command since Home Manager is now installed as part of your
configuration:

```shell
home-manager switch --flake .
```

**Note that neovim and tmux plugins are managed by their respective plugin
managers, so you'll need to install them manually after the initial
configuration is applied.**

## Legacy method

- Run install.sh to install the dependencies and config files
- Things must be done manually after install:
    - Install tmux if not present, then install tmux plugin manager and the
    plugins by pressing `prefix + I` while inside tmux
    - Install Cascadia Code NF fonts which is required by my alacritty config
    and can be found here: https://github.com/microsoft/cascadia-code
    - For neovim, some plugins may require go so please do install it:
    https://go.dev/doc/install

