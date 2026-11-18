# MetaDefender Core, repackaged from the official Debian package.
#
# The deb's tree is kept as-is under $out (usr/, etc/, var/) with every ELF
# patched by autoPatchelf. It still isn't runnable from the store: the product
# writes into its own install dir (/usr/lib/ometascan gets the bundled
# PostgreSQL's ometascan_postgres.{dat,cat}, patches/, pg18.dat, ...) and
# hardcodes FHS paths everywhere. nixos/mdcore.nix copies usr/lib/ometascan
# into a mutable state dir and bind-mounts things into place per service.
#
# Engines aren't in the deb. MD Core downloads them after licensing into
# /var/lib/ometascan/engines, unpatched, so those go through nix-ld instead
# (see the module).
#
# The bundled PostgreSQL ships its own copies of libs that also exist in the
# main tree (libssl, libcrypto, libpq, ...) at different versions. autoPatchelf
# resolves by soname across everything it's given, so postgres/ is patched in
# its own pass with only its own lib dir in scope.
{
  lib,
  stdenvNoCC,
  fetchurl,
  dpkg,
  autoPatchelfHook,
  stdenv,
  zlib,
  db53,
  libxcrypt-legacy,
  fontconfig,
  freetype,
  libx11,
  libxext,
  libxrender,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "metadefender-core";
  version = "5.24.0-1";

  src = fetchurl {
    url = "https://installer-cdn.opswat.com/Metadefender/Core/v5/${finalAttrs.version}/debian/ometascan_${finalAttrs.version}_amd64.deb";
    hash = "sha256-qvlinH22iWB6Tgtl0JhRiULup2XFNKBEFRYUgkkipco=";
  };

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
  ];

  # The deb's Depends, minus glibc (autoPatchelf supplies it) and the i386
  # bits, which are only there for engines.
  buildInputs = [
    stdenv.cc.cc.lib
    zlib
    db53
    libxcrypt-legacy # libcrypt.so.1
    fontconfig
    freetype
    libx11
    libxext
    libxrender
  ];

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb -x $src root
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -a root/. $out/
    # postinst does `chmod -R +x` over these; the deb itself ships most of
    # them (bundled postgres included) without exec bits.
    chmod -R +x $out/usr/lib/ometascan $out/usr/sbin $out/usr/bin
    runHook postInstall
  '';

  # Stripping or shrinking RPATHs on vendor binaries buys nothing and risks
  # breaking them; the patching is done by hand below instead of by the hook.
  dontStrip = true;
  dontPatchELF = true;
  dontAutoPatchelf = true;

  postFixup = ''
    # The original FHS dirs stay on the runpath: plugins (liboms*, Qt
    # plugins) are dlopen'd by bare name and expected to resolve there.
    pg=$out/usr/lib/ometascan/postgres
    appendRunpaths=(/usr/lib/ometascan/postgres/lib)
    autoPatchelf $pg

    # Hide postgres/ so its libs don't shadow the main tree's.
    mv $pg $TMPDIR/postgres
    appendRunpaths=(/usr/lib/ometascan)
    autoPatchelf $out/usr
    mv $TMPDIR/postgres $pg

    # The bundled PG runs OpenSSL in FIPS mode, and the FIPS provider checks
    # an HMAC of its own bytes (fips.so.mac). Patching it breaks that and every
    # PG connection then dies with "could not generate random cancel key".
    # It only needs glibc, which is already loaded when libcrypto dlopens it.
    fips=usr/lib/ometascan/postgres/lib/ossl-modules/fips.so
    dpkg-deb --fsys-tarfile $src | tar -xO ./$fips > $out/$fips
  '';

  meta = {
    description = "OPSWAT MetaDefender Core multi-engine anti-malware server";
    homepage = "https://www.opswat.com/products/metadefender/core";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
  };
})
