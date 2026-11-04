# Background computer-use driver for macOS (trycua/cua), packaged from the
# upstream release tarball. The driver speaks MCP over stdio and drives native
# apps through the Accessibility API, CGEventPostToPid and ScreenCaptureKit
# without moving the cursor or switching Spaces.
#
# Upstream ships a signed universal binary, so the fixup phase is disabled:
# stripping or re-signing it would invalidate the vendor signature and macOS
# refuses to launch it afterwards. libcua_driver_sdk.dylib and the node runtime
# are only needed for the embedding SDK and stay in $out/lib.
{
  lib,
  stdenvNoCC,
  fetchurl,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "cua-driver";
  version = "0.38.0";

  src = fetchurl {
    url = "https://github.com/trycua/cua/releases/download/cua-driver-rs-v${finalAttrs.version}/cua-driver-rs-${finalAttrs.version}-darwin-universal-binary.tar.gz";
    hash = "sha256-K7jcSn5pGF/9BMSpwOq1kL0sVLcsLBvhOrZ1vk9IdzI=";
  };

  sourceRoot = ".";
  dontConfigure = true;
  dontBuild = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    install -d $out/bin $out/lib
    install -m755 cua-driver $out/bin/cua-driver
    install -m755 cua-cursor-theme $out/bin/cua-cursor-theme
    install -m755 libcua_driver_sdk.dylib $out/lib/libcua_driver_sdk.dylib
    install -m644 cua_driver_abi.h $out/lib/cua_driver_abi.h

    runHook postInstall
  '';

  meta = {
    description = "Background computer-use driver for macOS agents";
    homepage = "https://github.com/trycua/cua";
    license = lib.licenses.mit;
    mainProgram = "cua-driver";
    platforms = [
      "aarch64-darwin"
      "x86_64-darwin"
    ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
})
