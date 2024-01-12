#!/bin/bash

# The .dotfiles absolute path where you cloned the repo
DOTFILES="$HOME/.dotfiles"

# install packages
# https://unix.stackexchange.com/a/571192
packagesNeeded='zsh bat exa fzf git-delta'
if [ -x "$(command -v apk)" ];       then sudo apk add --no-cache $packagesNeeded
elif [ -x "$(command -v apt-get)" ]; then sudo apt-get install $packagesNeeded
elif [ -x "$(command -v dnf)" ];     then sudo dnf install $packagesNeeded
elif [ -x "$(command -v zypper)" ];  then sudo zypper install $packagesNeeded
elif [ -x "$(command -v brew)" ];  then brew install $packagesNeeded
else echo "FAILED TO INSTALL PACKAGE: Package manager not found. You must manually install: $packagesNeeded">&2; fi

# install nvm and node
echo "Installing nvm..."
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash
export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" # This loads nvm
nvm install --lts
nvm use default

ln -sf $DOTFILES/zshrc $HOME/.zshrc

mkdir -p $HOME/.config/alacritty
ln -sf $DOTFILES/alacritty/alacritty.toml $HOME/.config/alacritty/alacritty.toml
ln -sf $DOTFILES/alacritty/alacritty-light.toml $HOME/.config/alacritty/alacritty-light.toml
ln -sf $DOTFILES/alacritty/alacritty-dark.toml $HOME/.config/alacritty/alacritty-dark.toml
cp $DOTFILES/alacritty/alacritty.local.toml $HOME/.config/alacritty/

# AstroNvim
if [[ -d "$HOME/.config/nvim" ]]; then
  echo "Installing AstroNvim..."
  git clone --depth 1 https://github.com/AstroNvim/AstroNvim $HOME/.config/nvim || true
  ln -sfn $DOTFILES/astronvim.config $HOME/.config/nvim/lua/user
fi

# install oh my zsh
echo "Installing oh-my-zsh..."
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

# install zsh plugins
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting || true
git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
if ! which zsh-history-enquirer > /dev/null; then
  npm i -g zsh-history-enquirer
fi

# change git diff to use delta
echo "Configuring git delta"
git config --global core.pager delta
git config --global interactive.diffFilter "delta --color-only"
git config --global delta.navigate true
git config --global delta.line-numbers true
git config --global merge.conflictstyle diff3
git config --global diff.colorMoved default

zsh

