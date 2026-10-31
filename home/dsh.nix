# DeepSeek Harness: the `dsh` CLI, the `dst` launcher, and the dsh-tui profile.
#
# The CLI comes from nixpkgs-unstable. That package is a full source build (the
# web frontend is built too) and it is marked Linux-only upstream, but the pnpm
# build is portable: it has been built and smoke-tested on aarch64-darwin
# (0.2.1-rc.3), which is why the platform list is widened below. Drop the
# override once nixpkgs carries darwin in meta.platforms.
#
# The Desktop app is a separate, manual install and is not referenced here — it
# self-updates, and packaging a 347MB binary that rewrites itself would fight
# the updater.
#
# Profile files ($DSH_HOME/profiles/<name>/{package.json,cordis.patch.yml}) are
# also not managed here: the app and plugin manager rewrite them through
# @deepseek-ai/dsh-atomic-write (temp file + rename), which replaces a symlink
# with a regular file. Those stay owned by whichever surface wrote them; the
# shared instructions and skills that nix does own are fanned out to $DSH_HOME
# in ./desktop.nix.
{
  pkgs,
  lib,
  unstablePkgs,
  ...
}:
let
  dsh = unstablePkgs.deepseek-harness.overrideAttrs (old: {
    meta = old.meta // {
      platforms = old.meta.platforms ++ lib.platforms.darwin;
    };
  });

  # The terminal UI is a third-party dsh profile bundle
  # (github.com/ccch1mneyyy/dsh-TUI). Its profile is pnpm-owned, so bump this by
  # hand; `dst update` also works and rewrites the profile itself.
  tuiVersion = "0.17.0";

  # The TUI's own launcher knows `safe`, `update`, `doctor` and the `run`
  # automation CLI, so prefer it once the profile is installed.
  dst = pkgs.writeShellScriptBin "dst" ''
    profile="$HOME/.dsh/profiles/dsh-tui"
    if [ ! -e "$profile/package.json" ]; then
      echo "dst: the dsh-tui profile is not installed yet" >&2
      echo "  dsh plugin --profile dsh-tui add @deepseek-harness-tui/dsh-tui" >&2
      exit 1
    fi
    if [ -x "$profile/node_modules/.bin/dsh-tui" ]; then
      exec "$profile/node_modules/.bin/dsh-tui" "$@"
    fi
    exec ${dsh}/bin/dsh --profile dsh-tui "$@"
  '';
in
{
  home.packages = [
    dsh
    dst
  ];

  # Create the dsh-tui profile once. A missing registry must not fail a switch,
  # so the install is time-boxed and its failure is a warning, not an error.
  home.activation.dshTuiProfile = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    profile="$HOME/.dsh/profiles/dsh-tui"
    if [ ! -e "$profile/node_modules/@deepseek-harness-tui/dsh-tui/package.json" ]; then
      echo "dsh: creating the dsh-tui profile (one-time network install)"
      ${pkgs.coreutils}/bin/timeout 300 \
        ${dsh}/bin/dsh plugin --profile dsh-tui \
          add "@deepseek-harness-tui/dsh-tui@${tuiVersion}" \
        || echo "dsh: dsh-tui install failed; retry with: dsh plugin --profile dsh-tui add @deepseek-harness-tui/dsh-tui@${tuiVersion}" >&2
    fi
  '';
}
