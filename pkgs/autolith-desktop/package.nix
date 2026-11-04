{
  lib,
  buildNpmPackage,
  electron,
  makeWrapper,
}:

buildNpmPackage {
  pname = "autolith-desktop";
  version = "0.1.0";
  src = ../../autolith-desktop;
  npmDepsHash = "sha256-I6I7CGZ+mJv2MW622X15HsrmRyXI6BgXdyDweaJ4RgU=";

  env.ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    app="$out/share/autolith-desktop"
    mkdir -p "$app"
    cp -r dist package.json "$app/"
    install -Dm644 ui/LICENSE.md "$out/share/licenses/autolith-desktop/shadcn-ui.md"
    makeWrapper "${lib.getExe electron}" "$out/bin/autolith-desktop" \
      --add-flags "$app"
    runHook postInstall
  '';

  meta.mainProgram = "autolith-desktop";
}
