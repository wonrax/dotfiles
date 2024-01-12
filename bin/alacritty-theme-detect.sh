#!/bin/sh

if [[ $TERM != "alacritty" ]]; then
  exit 0;
fi

function setTheme() {
  preference=$(gsettings get org.gnome.desktop.interface color-scheme)

  CONFIG_PATH="$HOME/.config/alacritty/alacritty.local.toml"
  LIGHT="alacritty-light"
  DARK="alacritty-dark"

  if [[ "$preference" = "'prefer-dark'" ]]; then
    if grep "$LIGHT" "$CONFIG_PATH" > /dev/null; then
      echo "Setting alacritty to dark"
      sed -i "s/$LIGHT/$DARK/" "$CONFIG_PATH"
    fi
  else
    if grep "$DARK" "$CONFIG_PATH" > /dev/null; then
      echo "Setting alacritty to light"
      sed -i "s/$DARK/$LIGHT/" "$CONFIG_PATH"
    fi
  fi
}

unameOut=$(uname -a)
case "${unameOut}" in
    *Microsoft*)     OS="WSL";; #must be first since Windows subsystem for linux will have Linux in the name too
    *microsoft*)     OS="WSL2";; #WARNING: My v2 uses ubuntu 20.4 at the moment slightly different name may not always work
    Linux*)     OS="Linux";;
    Darwin*)    OS="Mac";;
    CYGWIN*)    OS="Cygwin";;
    MINGW*)     OS="Windows";;
    *Msys)     OS="Windows";;
    *)          OS="UNKNOWN:${unameOut}"
esac

if [[ $OS = "Linux" ]]; then
  setTheme
fi

