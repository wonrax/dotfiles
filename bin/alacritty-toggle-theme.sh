#!/usr/bin/env bash

# TODO: alacritty from nixpkgs does not have TERM set to
# alacritty
# if [[ $TERM != "alacritty" ]]; then
# 	exit 0
# fi

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

macos_is_dark() {
	test "$(defaults read -g AppleInterfaceStyle 2>/dev/null)" == "Dark"
}

linux_is_dark() {
	preference=$(gsettings get org.gnome.desktop.interface color-scheme)
	test "$preference" = "'prefer-dark'"
}

change_theme() {
	# Because sed is different on Mac and Linux
	if [[ $OS = "Mac" ]]; then
		sed -i '' -e "s/$1/$2/" "$3"
	else
		sed -i "s/$1/$2/" "$3"
	fi
}

function setTheme() {
	isDark=false

	if [[ $OS = "Mac" ]]; then
		if macos_is_dark; then isDark=true; fi
	else
		if linux_is_dark; then isDark=true; fi
	fi

	echo $testDark

	CONFIG_PATH="$HOME/.dotfiles/.config/alacritty/alacritty.local.toml"
	LIGHT="alacritty-light"
	DARK="alacritty-dark"

	if [[ $isDark == true ]]; then
		if grep "$LIGHT" "$CONFIG_PATH" >/dev/null; then
			change_theme $LIGHT $DARK $CONFIG_PATH
		fi
	else
		if grep "$DARK" "$CONFIG_PATH" >/dev/null; then
			change_theme $DARK $LIGHT $CONFIG_PATH
		fi
	fi
}

if [[ $OS = "Linux" || $OS = "Mac" ]]; then
	setTheme
fi
