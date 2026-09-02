# ChatGPT Desktop for Linux, vendored from nixpkgs PR #551713 (head as of
# 2026-08-30, after the force-push that folded in the review fixes). Delete
# this file and switch to the nixpkgs package once the PR lands. The competing
# PR #551852 is a simpler take on the same deb (mutable /latest URL, no
# detect-libc fix) and is effectively superseded.
#
# Upstream quirks this packaging carries, learned the hard way in the PR
# discussion:
# - autoPatchelf grows the ELF header, moving PT_INTERP beyond detect-libc's
#   2 KiB scan. Its process.report fallback trips Electron's CFI and the app
#   dies with SIGILL as soon as the Git repo watcher starts (i.e. when opening
#   any Git-backed Codex thread). postPatch pins the glibc watcher via a
#   byte-for-byte sed of app.asar: the trailing spaces in the replacement are
#   LOAD-BEARING padding — pattern and replacement must both be 28 bytes or
#   every asar payload offset after the match goes stale while the build stays
#   green. We assert the file size is unchanged for that reason.
# - The bundled plugins live in the read-only store, but Electron rewrites
#   their manifests in place. The launcher stages a writable per-version copy
#   under ~/.cache/chatgpt/bundled-plugins (flock'd, atomically published) and
#   points the app at it via CODEX_ELECTRON_BUNDLED_PLUGINS_RESOURCES_PATH.
# - Newer debs ship musl prebuilds that autoPatchelf chokes on; every prebuild
#   not matching this platform/arch is pruned.
# - OpenAI's Electron fork defaults to XWayland and ignores
#   --ozone-platform-hint; native Wayland only engages via the explicit flag
#   and is documented as experimental (focus/shortcut caveats). The launcher
#   only opts in when NIXOS_OZONE_WL is set — unset on peggy, so the app runs
#   through xwayland-satellite under niri.
#
# Deviations from the PR:
# - Linux-only: the darwin branch is dropped, the macs use the official
#   self-updating app.
# - source.json and launcher.nix are inlined here to keep one file.
# - passwordStore defaults to "gnome-libsecret" for the same reason as
#   claude-desktop.nix: electron only auto-detects a keyring backend on
#   GNOME/KDE, and under niri it silently falls back to the plaintext store.
#   Requires the gnome-keyring daemon (enabled in nixos/system.nix).
# - postPatch asserts app.asar's size is unchanged after the sed (suggested in
#   review but not adopted upstream yet).
#
# The bundled codex/codex-code-mode-host are replaced with the nixpkgs codex
# (which ships both binaries); pass codex = null to run the bundled ones
# instead if the app and system codex ever drift incompatibly.
{
  lib,
  stdenv,
  fetchurl,

  ### Hooks
  autoPatchelfHook,
  dpkg,
  makeWrapper,
  wrapGAppsHook3,
  qt6,

  ### Launcher
  writeShellApplication,
  flock,

  ### Electron/Chromium
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  dconf,
  expat,
  gdk-pixbuf,
  glib,
  gtk3,
  libgbm,
  libnotify,
  libusb1,
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxkbcommon,
  libxrandr,
  nspr,
  nss,
  pango,
  systemdLibs,

  ### Dlopen'd at runtime
  libGL,
  libpulseaudio,
  libsecret,
  pipewire,
  vulkan-loader,

  ### Host tools the app and bundled plugins exec
  bubblewrap,
  nodejs-slim,
  ripgrep,
  tectonic-unwrapped,
  xdg-utils,

  ### Override to null to use the bundled codex
  codex,

  ### Force a specific password store backend
  passwordStore ? "gnome-libsecret",
}:

let
  inherit (stdenv.hostPlatform) system;
  inherit (stdenv.hostPlatform.node) arch platform;

  sources = {
    x86_64-linux = {
      version = "26.831.21537";
      url = "https://persistent.oaistatic.com/codex-app-prod/linux/deb/pool/main/c/chatgpt/chatgpt_26.831.21537_amd64.deb";
      hash = "sha256-XBVu8qLgKRWW0HuuhmDvTwt0jfO6+Rv8ko97XjxhCxE=";
    };
    aarch64-linux = {
      version = "26.831.21537";
      url = "https://persistent.oaistatic.com/codex-app-prod/linux/deb/pool/main/c/chatgpt/chatgpt_26.831.21537_arm64.deb";
      hash = "sha256-LT1oQMEb9AANb/e9uwqg25LfTOBiIIEu1U80pnc1BPc=";
    };
  };

  source = sources.${system} or (throw "chatgpt is not supported on ${system}");

  launcher = writeShellApplication {
    name = "chatgpt-launcher";

    runtimeInputs = [ flock ];

    text = ''
      : "''${CHATGPT_EXECUTABLE:?}"
      : "''${CHATGPT_RESOURCES_SOURCE:?}"
      : "''${CHATGPT_RESOURCES_CACHE_LABEL:?}"

      cacheHome="''${XDG_CACHE_HOME:-''${HOME:?XDG_CACHE_HOME and HOME are unset}/.cache}"
      cacheRoot="$cacheHome/chatgpt/bundled-plugins"
      resourcesSourceHash=$(printf '%s' "$CHATGPT_RESOURCES_SOURCE" | sha256sum)
      resourcesSourceHash="''${resourcesSourceHash%% *}"
      cacheKey="$CHATGPT_RESOURCES_CACHE_LABEL-$resourcesSourceHash"
      resourcesPath="$cacheRoot/$cacheKey"

      mkdir -p "$cacheRoot/.locks"
      resourcesLockPath="$cacheRoot/.locks/$cacheKey.lock"
      exec {resourcesLockFd}> "$resourcesLockPath"
      flock --shared "$resourcesLockFd"

      stagingLockPath="$cacheRoot/.locks/staging-v1.lock"
      exec {stagingCleanupLockFd}> "$stagingLockPath"
      if flock --exclusive --nonblock "$stagingCleanupLockFd"; then
        for abandonedStagingPath in "$cacheRoot"/.chatgpt-staging-v1-*; do
          if [[ -d "$abandonedStagingPath" ]] && ! rm -rf -- "$abandonedStagingPath"; then
            echo "Failed to remove abandoned ChatGPT bundled-plugin staging directory: $abandonedStagingPath" >&2
          fi
        done
      fi
      exec {stagingCleanupLockFd}>&-

      requiredResourcePaths=()
      for requiredResourceName in codex codex-code-mode-host cua_node native rg; do
        requiredResourcePath="$CHATGPT_RESOURCES_SOURCE/$requiredResourceName"
        if [[ ! -e "$requiredResourcePath" ]]; then
          echo "Missing ChatGPT bundled-plugin resource: $requiredResourcePath" >&2
          exit 1
        fi
        requiredResourcePaths+=("$requiredResourcePath")
      done

      if [[ ! -f "$resourcesPath/.complete" ]]; then
        exec {stagingWriterLockFd}> "$stagingLockPath"
        flock --shared "$stagingWriterLockFd"
        stagingPath=$(mktemp -d "$cacheRoot/.chatgpt-staging-v1-$cacheKey.XXXXXXXX")
        trap 'rm -rf -- "$stagingPath"' EXIT

        ln -s "''${requiredResourcePaths[@]}" "$stagingPath"
        cp -R "$CHATGPT_RESOURCES_SOURCE/plugins" "$stagingPath/plugins"
        chmod -R u+w "$stagingPath/plugins"
        touch "$stagingPath/.complete"

        # Flush the payload and commit marker before exposing the cache atomically.
        sync --file-system "$stagingPath"

        if mv -T "$stagingPath" "$resourcesPath" 2>/dev/null; then
          sync --file-system "$cacheRoot"
          trap - EXIT
        elif [[ -f "$resourcesPath/.complete" ]]; then
          rm -rf -- "$stagingPath"
          trap - EXIT
        else
          echo "Failed to publish ChatGPT's writable bundled-plugin resources" >&2
          exit 1
        fi
        exec {stagingWriterLockFd}>&-
      fi

      # Only lock-aware published caches can be removed safely.
      for obsoletePath in "$cacheRoot"/*; do
        if [[ "$obsoletePath" != "$resourcesPath" && -f "$obsoletePath/.complete" ]]; then
          obsoleteKey="''${obsoletePath##*/}"
          obsoleteLockPath="$cacheRoot/.locks/$obsoleteKey.lock"

          # Caches without a lock predate this protocol and may still be in use.
          if [[ -f "$obsoleteLockPath" ]]; then
            exec {obsoleteLockFd}> "$obsoleteLockPath"
            if flock --exclusive --nonblock "$obsoleteLockFd"; then
              if ! rm -rf -- "$obsoletePath"; then
                echo "Failed to remove obsolete ChatGPT bundled-plugin cache: $obsoletePath" >&2
              fi
            fi
            exec {obsoleteLockFd}>&-
          fi
        fi
      done

      export CODEX_ELECTRON_BUNDLED_PLUGINS_RESOURCES_PATH="$resourcesPath"

      waylandFlags=()
      if [[ -n "''${NIXOS_OZONE_WL:-}" && -n "''${WAYLAND_DISPLAY:-}" ]]; then
        waylandFlags=(
          --ozone-platform=wayland
          --enable-features=WaylandWindowDecorations
          --enable-wayland-ime=true
        )
      fi

      exec "$CHATGPT_EXECUTABLE" "''${waylandFlags[@]}" "$@"
    '';
  };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "chatgpt";
  inherit (source) version;

  src = fetchurl { inherit (source) url hash; };

  strictDeps = true;
  __structuredAttrs = true;

  # autoPatchelf moves PT_INTERP beyond detect-libc's 2 KiB scan. Its
  # process.report fallback trips Electron's CFI, so use the glibc watcher.
  # Pattern and replacement are both 28 bytes; the padding is intentional.
  postPatch = ''
    asar=usr/lib/chatgpt/resources/app.asar
    asarSize=$(stat -c%s "$asar")
    grep -aFq 'const family = familySync();' "$asar"
    sed -i "s|const family = familySync();|const family = 'glibc'     ;|" "$asar"
    if [[ $(stat -c%s "$asar") != "$asarSize" ]]; then
      echo "app.asar changed size after the detect-libc patch" >&2
      exit 1
    fi
  '';

  nativeBuildInputs = [
    autoPatchelfHook
    dpkg
    makeWrapper
    qt6.wrapQtAppsHook
    wrapGAppsHook3
  ];

  buildInputs = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    dconf
    expat
    gdk-pixbuf
    glib
    gtk3
    libgbm
    libnotify
    libusb1
    libx11
    libxcb
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxkbcommon
    libxrandr
    nspr
    nss
    pango
    qt6.qtbase
    stdenv.cc.cc.lib
    systemdLibs
  ];

  runtimeDependencies = [
    libGL
    libnotify
    libpulseaudio
    libsecret
    pipewire
    vulkan-loader
  ];

  dontWrapGApps = true;
  dontWrapQtApps = true;

  sourceRoot = "root";

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp -r usr/* "$out"

    # Remove the unused Qt 5 fallback shim.
    rm -f "$out/lib/chatgpt/libqt5_shim.so"

    # Keep only the native prebuild for this platform and architecture.
    resources="$out/lib/chatgpt/resources"
    find "$resources" -type d -name prebuilds -print0 | while IFS= read -r -d "" prebuildsPath; do
      find "$prebuildsPath" -mindepth 1 -maxdepth 1 \
        ! -name "*${platform}-${arch}" \
        -exec rm -rf -- {} +
    done
    find "$resources" -type f -name '*.musl.node' -delete

    ln -sf ${lib.getExe tectonic-unwrapped} "$out/lib/chatgpt/resources/plugins/openai-bundled/plugins/latex/bin/tectonic"
    ln -sf ${lib.getExe ripgrep} "$out/lib/chatgpt/resources/rg"
    ln -sf ${lib.getExe nodejs-slim} "$out/lib/chatgpt/resources/cua_node/bin/node"

    install -Dm755 ${lib.getExe launcher} "$out/bin/chatgpt"
  ''
  + lib.optionalString (codex != null) ''
    ln -sf ${lib.getExe codex} "$out/lib/chatgpt/resources/codex"
    ln -sf ${lib.getExe' codex "codex-code-mode-host"} "$out/lib/chatgpt/resources/codex-code-mode-host"
  ''
  + ''
    runHook postInstall
  '';

  postFixup = ''
    wrapProgram "$out/bin/chatgpt" \
      "''${gappsWrapperArgs[@]}" \
      "''${qtWrapperArgs[@]}" \
      --set CHATGPT_EXECUTABLE "$out/lib/chatgpt/ChatGPT" \
      --set CHATGPT_RESOURCES_SOURCE "$out/lib/chatgpt/resources" \
      --set CHATGPT_RESOURCES_CACHE_LABEL ${lib.escapeShellArg "${finalAttrs.version}-${system}"} \
      --prefix PATH : ${
        lib.makeBinPath [
          nodejs-slim
          xdg-utils
          bubblewrap
        ]
      } \
      --set-default CODEX_BROWSER_USE_NODE_PATH ${lib.getExe nodejs-slim} \
      --set-default NODE_REPL_NODE_PATH ${lib.getExe nodejs-slim} \
      ${lib.escapeShellArgs (
        lib.optionals (codex != null) [
          "--set-default"
          "CODEX_CLI_PATH"
          (lib.getExe codex)
        ]
      )} \
      ${lib.optionalString (passwordStore != null) ''
        --add-flags "--password-store=${passwordStore}"
      ''}
  '';

  dontStrip = true;

  passthru = {
    inherit launcher;
  };

  meta = {
    description = "Desktop application for ChatGPT";
    homepage = "https://developers.openai.com/codex/app";
    changelog = "https://learn.chatgpt.com/docs/changelog";
    license = lib.licenses.unfree;
    mainProgram = "chatgpt";
    platforms = lib.attrNames sources;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
})
