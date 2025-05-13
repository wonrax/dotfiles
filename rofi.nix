# A collection of rofi themed launchers
# Nix derivation inspired by:
# https://github.com/olaberglund/nixos-config/blob/b20df0/pkgs/rofi/package.nix

# NOTE: this won't work well with wayland as it causes focusing and window
# alignment issues as being discussed in:
# https://github.com/swaywm/sway/issues/267
# But I still want to keep it here for future reference, e.g. when I switch to
# X11 where it might work better.
# Example usage:
# ```nix
# { pkgs, ... }:
# let
#   rofi-launchers = pkgs.callPackage ./rofi.nix { };
# in
# {
#   home.packages = with pkgs; [
#     rofi
#     rofi-launchers.package
#   ];
#
#   dconf.settings = {
#     "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" = {
#       binding = "<Super>space";
#       command = pkgs.lib.getExe rofi-launchers.launch;
#       name = "Launch Rofi";
#     };
#   }
# }
# ```

{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  rofi,
  writeShellScriptBin,
}:
rec {
  package = stdenvNoCC.mkDerivation {
    name = "rofi-launchers";

    src = fetchFromGitHub {
      owner = "adi1090x";
      repo = "rofi";
      rev = "86e6875d9e89ea3cf95c450cef6497d52afceefe";
      hash = "sha256-4mL2jLxRYZI3A9ByXfbzwkkoTaL7WMXHVx4FIQmd9oY=";
    };

    buildInputs = [ rofi ];

    postPatch = ''
      files=$(find files/scripts -type l)
      for file in $files; do
        substituteInPlace $file \
          --replace-fail '$HOME/.config/rofi' "$out/share" \
          --replace-fail "rofi " "${lib.getExe rofi} "
      done

      files=$(find files/launchers -type f -name "*.rasi")
      for file in $files; do
        substituteInPlace $file \
          --replace-quiet '~/.config/rofi' "$out/share"
      done

      substituteInPlace files/launchers/type-1/shared/fonts.rasi \
        --replace-fail 'JetBrains Mono Nerd Font 10' 'JetBrains Mono Nerd Font 13'
    '';

    installPhase = ''
      runHook preInstall

      # Install all scripts as binaries
      mkdir -p $out/bin
      for script in files/scripts/*; do
        install -Dm755 $script $out/bin/$(basename $script)
      done

      # Install Fonts
      mkdir -p "$out/share/fonts"
      cp -r fonts/* "$out/share/fonts"

      # Install other necessary files
      mkdir -p "$out/share"
      cp -r files/* "$out/share"

      runHook postInstall
    '';

    meta = {
      description = "A collection of rofi launchers";
      homepage = "https://github.com/adi1090x/rofi";
      platforms = lib.platforms.linux;
    };
  };

  launch = writeShellScriptBin "rofi-launcher" ''
    dir="${package}/share/launchers/type-1"
    theme='style-5'

    ## Run
    ${lib.getExe rofi} \
      -show drun \
      -theme $dir/$theme.rasi
  '';
}
