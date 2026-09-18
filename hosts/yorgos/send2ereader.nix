{
  lib,
  pkgs,
  ...
}:
# send2ereader — upload an ebook from a phone/laptop, fetch it from the
# Kobo/Kindle built-in browser (kobo.wrx.sh). Upstream publishes no image, so
# we pin the source with nix and `podman build` the upstream Dockerfile on the
# host. The image is tagged by source rev, so bumping `rev` + `hash` triggers a
# rebuild on the next switch and the old tag is left for `podman image prune`.
# The source is our fork (github.com/wonrax/send2ereader); currently identical
# to upstream eb0b646.
let
  src = pkgs.fetchFromGitHub {
    owner = "wonrax";
    repo = "send2ereader";
    rev = "eb0b646191d654aa4ab52a185151aa34f359f889";
    hash = "sha256-tmxEJ0yQChyNYW4iPbFe1jX6qXLCBFdvEV4RvANnqqc=";
  };
  image = "localhost/send2ereader:${builtins.substring 0 12 src.rev}";
in
{
  # Builds the image once per pinned rev. Needs network: the Dockerfile pulls
  # node:lts-alpine and downloads kepubify/kindlegen/pdfCropMargins.
  systemd.services."podman-build-send2ereader" = {
    path = [ pkgs.podman ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if podman image exists ${image}; then
        echo "image ${image} already built"
        exit 0
      fi
      podman build --pull=newer -t ${image} ${src}
    '';
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
  };

  virtualisation.oci-containers.containers.send2ereader = {
    inherit image;
    # Uploads live in the container's ephemeral /usr/src/app/uploads and are
    # wiped on every start by the app itself, so no volume.
    ports = [ "127.0.0.1:3001:3001" ];
    log-driver = "journald";
    extraOptions = [
      "--memory=512m"
    ];
  };

  systemd.services."podman-send2ereader" = {
    serviceConfig.Restart = lib.mkOverride 90 "always";
    after = [ "podman-build-send2ereader.service" ];
    requires = [ "podman-build-send2ereader.service" ];
  };
}
