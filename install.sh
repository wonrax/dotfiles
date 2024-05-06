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
packagesNeeded='zsh bat eza fzf git-delta ripgrep'
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
# We're not replacing local config if the nvim folder existed otherwise the ln
# -sf will create a symlink inside the nvim folder instead
if [[ ! -d "$HOME/.config/nvim" ]]; then
	echo "Creating a local nvim config"
	ln -sf $DOTFILES/.config/nvim $HOME/.config/nvim
fi

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
[[ ! "${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting" ]] &&
	git clone https://github.com/zsh-users/zsh-syntax-highlighting.git \
		${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
[[ ! "${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions" ]] &&
	git clone https://github.com/zsh-users/zsh-autosuggestions \
		${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
[[ ! "${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/forgit" ]] &&
	git clone https://github.com/wfxr/forgit.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/forgit
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

zsh
