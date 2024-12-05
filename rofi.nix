# https://github.com/olaberglund/nixos-config/blob/b20df0/pkgs/rofi/package.nix

{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  rofi,
}:

stdenvNoCC.mkDerivation {
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
    maintainers = with lib.maintainers; [ ];
    platforms = lib.platforms.linux;
  };
}