{
  pkgs,
}:

let
  # Build the MediaRemote Adapter framework
  mediaremote-adapter = pkgs.stdenv.mkDerivation {
    pname = "mediaremote-adapter";
    version = "0.7.2";

    src = pkgs.fetchFromGitHub {
      owner = "ungive";
      repo = "mediaremote-adapter";
      rev = "6bbb7d30f9ddb209a583fa509b9ca145df97f502";
      sha256 = "sha256-K8McJV1OzOxS62bIaGHOw6bPjZl1loHeIW9LmRf4WV0=";
    };

    # Patch out hardcoded codesign - Nix handles ad-hoc signing
    postPatch = ''
      substituteInPlace CMakeLists.txt \
        --replace "codesign" "echo 'Skipping manual codesign'"
    '';

    nativeBuildInputs = [ pkgs.cmake ];

    installPhase = ''
      mkdir -p $out/bin $out/Frameworks
      cp ../bin/mediaremote-adapter.pl $out/bin/mediaremote-adapter.pl
      chmod +x $out/bin/mediaremote-adapter.pl
      cp -r MediaRemoteAdapter.framework $out/Frameworks/
    '';
  };

  # Build the Starship daemon
  starship-daemon = pkgs.stdenv.mkDerivation {
    pname = "starship-daemon";
    version = "1.0.0";

    src = ./starship-daemon.swift;

    buildInputs = [ pkgs.swift ];
    dontUnpack = true;

    buildPhase = ''
      cp $src built.swift

      # Inject Nix store paths into Swift source
      substituteInPlace built.swift \
        --replace "@ADAPTER_BIN@" "${mediaremote-adapter}/bin/mediaremote-adapter.pl" \
        --replace "@FRAMEWORK_PATH@" "${mediaremote-adapter}/Frameworks/MediaRemoteAdapter.framework"

      swiftc -O -o starship-daemon built.swift
    '';

    installPhase = ''
      mkdir -p $out/bin
      cp starship-daemon $out/bin/
    '';
  };

in
starship-daemon
