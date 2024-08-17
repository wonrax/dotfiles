#!/bin/bash

# The installation script to setup the dotfiles on a machine. The script is
# designed to be idempotent, meaning it can be run multiple times without
# causing any issues.

# The .dotfiles absolute path where you cloned the repo
DOTFILES="$HOME/.dotfiles"

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
# Install essential packages
# https://unix.stackexchange.com/a/571192
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
packagesNeeded='zsh bat eza fzf git-delta ripgrep gh'
if [ -x "$(command -v apk)" ]; then
	sudo apk add --no-cache $packagesNeeded
elif [ -x "$(command -v apt-get)" ]; then
	echo "apt detected, removing git-delta from packagesNeeded." \
		"Please install manually"
	packagesNeeded=$(echo "$packagesNeeded" | sed 's/git-delta//')
	sudo apt-get install $packagesNeeded
elif [ -x "$(command -v dnf)" ]; then
	sudo dnf install $packagesNeeded
elif [ -x "$(command -v zypper)" ]; then
	sudo zypper install $packagesNeeded
elif [ -x "$(command -v brew)" ]; then
	brew install $packagesNeeded
else echo "FAILED TO INSTALL PACKAGE: Package manager not found." \
	"You must manually install: $packagesNeeded" >&2; fi

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
# Install nvm and Node
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
if [[ ! -d "$NVM_DIR" ]]; then
	echo "Installing nvm..."
	curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash
	export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" ||
		printf %s "${XDG_CONFIG_HOME}/nvm")"
	[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" # This loads nvm
	echo "Installing Node..."
	nvm install --lts
	nvm use default
fi

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
# Alacritty config
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
# We're not replacing local config if existed
if [[ ! -f "$DOTFILES/.config/alacritty/alacritty.toml" ]]; then
	echo "Creating a local alacritty config: alacritty.toml"
	cp $DOTFILES/.config/alacritty/alacritty.toml.template \
		$DOTFILES/.config/alacritty/alacritty.toml
fi
mkdir -p $HOME/.config/alacritty
ln -sf $DOTFILES/.config/alacritty/alacritty.toml \
	$HOME/.config/alacritty/alacritty.toml
ln -sf $DOTFILES/.config/alacritty/alacritty.base.toml \
	$HOME/.config/alacritty/alacritty.base.toml
ln -sf $DOTFILES/.config/alacritty/alacritty-light.toml \
	$HOME/.config/alacritty/alacritty-light.toml
ln -sf $DOTFILES/.config/alacritty/alacritty-dark.toml \
	$HOME/.config/alacritty/alacritty-dark.toml

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
# Neovim config
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
# We're not replacing the neovim config if the nvim folder existed otherwise
# the ln -sf will create a symlink inside the nvim folder instead
if [[ ! -d "$HOME/.config/nvim" ]]; then
	echo "Creating a local nvim config"
	ln -sf $DOTFILES/.config/nvim $HOME/.config/nvim
fi

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
# Tmux config
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
# We're not replacing tmux config if the tmux folder existed otherwise the ln
# -sf will create a symlink inside the tmux folder instead
if [[ ! -d "$HOME/.config/tmux" ]]; then
	echo "Creating a local tmux config"
	ln -sf $DOTFILES/.config/tmux $HOME/.config/tmux
fi
# Link the tmux.conf file to home directory because macOS doesn't support
# symlinks in the ~/.config folder
ln -sf $DOTFILES/.config/tmux/tmux.conf $HOME/.tmux.conf
# TPM
[[ ! -d "$HOME/.tmux/plugins/tpm" ]] &&
	git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
# Install and config Oh My Zsh
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
if [[ ! -d "$ZSH" ]]; then
	echo "Installing Oh My Zsh..."
	curl -fsSL \
		https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh |
		sh
	ln -sf $DOTFILES/zshrc $HOME/.zshrc
fi

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
# Install omz plugins
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
ZSH_CUSTOM_PLUGINS=${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins

# Create the custom plugins directory if it does not exist
mkdir -p $ZSH_CUSTOM_PLUGINS

clone_if_not_exists() {
    local repo_url=$1
    local target_dir="$ZSH_CUSTOM_PLUGINS/$(basename -s .git "$repo_url")"

    if [[ ! -d "$target_dir" ]]; then
        git clone "$repo_url" "$target_dir"
    fi
}

clone_if_not_exists "https://github.com/zsh-users/zsh-syntax-highlighting.git"
clone_if_not_exists "https://github.com/zsh-users/zsh-autosuggestions"
clone_if_not_exists "https://github.com/wfxr/forgit.git"
clone_if_not_exists "https://github.com/jeffreytse/zsh-vi-mode"

if ! which zsh-history-enquirer >/dev/null; then
	npm i -g zsh-history-enquirer
fi

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
# Git delta
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
echo "Configuring git delta"
git config --global core.pager delta
git config --global interactive.diffFilter "delta --color-only"
git config --global delta.navigate true
git config --global delta.line-numbers true
git config --global merge.conflictstyle diff3
git config --global diff.colorMoved default

echo "Configuring difftastic"
git config --global diff.tool difftastic
git config --global difftool.prompt false
git config --global difftool.difftastic.cmd 'difft "$LOCAL" "$REMOTE"'
git config --global pager.difftool true
git config --global alias.dft difftool

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
# Platform specific configurations
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
unameOut=$(uname -a)
case "${unameOut}" in
	*Microsoft*) OS="WSL" ;;  #must be first since Windows subsystem for linux will have Linux in the name too
	*microsoft*) OS="WSL2" ;; #WARNING: My v2 uses ubuntu 20.4 at the moment slightly different name may not always work
	Linux*) OS="Linux" ;;
	Darwin*) OS="Mac" ;;
	CYGWIN*) OS="Cygwin" ;;
	MINGW*) OS="Windows" ;;
	*Msys) OS="Windows" ;;
	*) OS="UNKNOWN:${unameOut}" ;;
esac

if [[ $OS = "Mac" ]]; then
	# Disable font smoothing in Alacritty on macOS so that it won't appear
	# bolder and harder to read on low resolution screens
	defaults write org.alacritty AppleFontSmoothing -int 0
fi

zsh
