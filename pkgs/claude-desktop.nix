# Claude Desktop for Linux, vendored from nixpkgs PR #537215 with the version
# bumped to the latest apt release. Delete this file and switch to the nixpkgs
# package once the PR lands.
#
# Deviations from the PR:
# - Cowork VM support stripped (qemu, OVMF, virtiofsd, app.asar path patching
#   and the /dev/kvm bwrap passthroughs) — we don't use Cowork and qemu alone
#   adds ~1GB to the closure.
# - passwordStore defaults to "gnome-libsecret": electron only auto-detects a
#   keyring backend on GNOME/KDE, so under niri it silently falls back to the
#   plaintext store and Claude refuses to persist sign-in. Requires a running
#   gnome-keyring daemon (enabled in nixos/system.nix).
#
# The FHS wrap is kept even without Cowork: the app self-downloads a
# dynamically linked Claude Code CLI to ~/.config/Claude/claude-code/ and execs
# it by absolute path, which needs an FHS /lib64/ld-linux interpreter.
{
  lib,
  fetchurl,
  stdenvNoCC,
  buildFHSEnv,

  ### Tools
  dpkg,
  autoPatchelfHook,
  makeWrapper,

  ### Electron/Chromium
  nss,
  nspr,
  mesa,
  alsa-lib,
  libxkbcommon,
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxrandr,
  at-spi2-atk,
  at-spi2-core,
  cups,
  dbus,
  gtk3,
  pango,
  cairo,
  expat,
  glib,
  systemd,

  ### For the bundled virtiofsd binary (autoPatchelf)
  libseccomp,
  libcap_ng,

  ### For keyring support
  libsecret,

  ### For extensions
  python3,
  nodejs,

  ### Sso login
  xdg-utils,

  ### Force a specific password store backend
  passwordStore ? "gnome-libsecret",
}:

let
  unwrapped = stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "claude-desktop";
    version = "1.19367.0";

    src =
      if stdenvNoCC.hostPlatform.system == "x86_64-linux" then
        fetchurl {
          url = "https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/claude-desktop/claude-desktop_${finalAttrs.version}_amd64.deb";
          hash = "sha256-dvVwcwwRhZJOJCPF+IonvsF8HnrbBV7NCUAaDpOpKZs=";
        }
      else if stdenvNoCC.hostPlatform.system == "aarch64-linux" then
        fetchurl {
          url = "https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/claude-desktop/claude-desktop_${finalAttrs.version}_arm64.deb";
          hash = "sha256-mKsOnizz7K4HOjjYHsq9K4XH5/4xnPct9XVkKRUEWoM=";
        }
      else
        throw "Unsupported system: ${stdenvNoCC.hostPlatform.system}";

    nativeBuildInputs = [
      dpkg
      autoPatchelfHook
      makeWrapper
    ];

    buildInputs = [
      ### Electron/Chromium
      nss
      nspr
      mesa
      alsa-lib
      libxkbcommon
      libx11
      libxcb
      libxcomposite
      libxdamage
      libxext
      libxfixes
      libxrandr
      at-spi2-atk
      at-spi2-core
      cups
      dbus
      gtk3
      pango
      cairo
      expat
      glib
      systemd

      ### Bundled virtiofsd
      libseccomp
      libcap_ng

      ### For keyring support
      libsecret

      ### For extensions
      python3
      nodejs

      ### For sso login
      xdg-utils
    ];

    unpackPhase = ''
      runHook preUnpack

      dpkg-deb --fsys-tarfile $src | tar --extract

      runHook postUnpack
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out
      mv usr/* $out

      runHook postInstall
    '';

    postFixup = ''
      wrapProgram $out/bin/claude-desktop \
        --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ libsecret ]} \
        --prefix PATH : ${
          lib.makeBinPath [
            python3
            nodejs
            xdg-utils
          ]
        } \
        ${lib.optionalString (passwordStore != null) ''
          --add-flags "--password-store=${passwordStore}"
        ''}
    '';

    meta = {
      description = "Desktop application for Claude.ai";
      homepage = "https://claude.ai/download";
      license = lib.licenses.unfree;
      platforms = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    };
  });

  fhsEnv = buildFHSEnv {
    pname = "claude-desktop-fhsenv";
    inherit (unwrapped) version;

    targetPkgs =
      pkgs: with pkgs; [
        unwrapped
        glibc
        python3
        nodejs
        libsecret
      ];

    extraInstallCommands = ''
      mkdir -p "$out/share"
      ln -s ${unwrapped}/share/* "$out/share/"
    '';

    runScript = "${unwrapped}/bin/claude-desktop";

    dieWithParent = false;
  };
in
stdenvNoCC.mkDerivation {
  pname = "claude-desktop";
  inherit (unwrapped) version;
  strictDeps = true;
  __structuredAttrs = true;

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    mkdir -p "$out/bin" "$out/share"
    ln -s ${fhsEnv}/bin/claude-desktop-fhsenv "$out/bin/claude-desktop"
    ln -s ${fhsEnv}/share/* "$out/share/"
  '';

  inherit (unwrapped) meta;
  passthru = {
    inherit unwrapped fhsEnv;
  };
}
