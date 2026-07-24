# agentflow as nix packages: the daemon behind a launchd agent, and the `af`
# CLI on PATH. Both run the source straight out of the store, so a
# `darwin-rebuild switch` after editing this directory is what deploys it — the
# store path changes, the launchd plist changes with it, and nix-darwin boots
# the agent out and back in on the new code.
{ pkgs }:
let
  lib = pkgs.lib;

  # A flake sees git-tracked files and nothing else, so .gitignore is already
  # doing the real work here: node_modules (~288M) never reaches the store on
  # the `git+file:` path that `darwin-rebuild --flake` uses. This filter is only
  # belt and braces for evaluation through the `path:` fetcher — `nix build -f`,
  # or `getFlake` on a bare path — which copies the working directory wholesale
  # and would otherwise drag node_modules and .jj in behind it.
  src = lib.cleanSourceWith {
    name = "agentflow-src";
    src = ./.;
    filter =
      path: type:
      let
        base = baseNameOf (toString path);
      in
      base != "node_modules" && base != ".agentflow-state" && !(lib.hasSuffix ".log" base);
  };

  # The other half of "git-tracked files and nothing else", and the half that
  # bites: a file you created but never `git add`ed is silently absent from the
  # store, and nix says nothing because it only errors for files it has to
  # *evaluate*. Everything below is read at runtime instead — the emit tool, the
  # dashboard, the SDK served at /sdk.ts — so a missing one surfaced as the
  # daemon failing hours later against a path that plainly exists on disk.
  # Checking here turns that into a build failure that names the fix.
  runtimeFiles = [
    "src/main.ts"
    "cli.ts"
    "sdk/standalone.ts"
    "web/index.html"
    "image/af-mcp.mjs"
  ];

  missing = builtins.filter (p: !builtins.pathExists "${src}/${p}") runtimeFiles;

  checkedSrc =
    if missing == [ ] then
      src
    else
      throw ''
        agentflow: these files are needed at runtime but are not in the flake source:
          ${lib.concatStringsSep "\n  " missing}
        A flake only sees git-tracked files. If they exist on disk, they are untracked —
        commit them, or make them visible without staging content:
          ${lib.concatStringsSep "\n  " (map (p: "git -C ~/.dotfiles add -N agentflow/${p}") missing)}
      '';

  # `nodeModulesDir: "auto"` in deno.json puts node_modules next to deno.json,
  # which is now a read-only store path. `none` resolves npm dependencies out of
  # DENO_DIR instead, which lives under the user's cache and is writable. The
  # first start after a dependency change fetches them, so it needs the network
  # that one time.
  deno = "${pkgs.deno}/bin/deno";
in
{
  src = checkedSrc;

  daemon = pkgs.writeShellScriptBin "agentflow-daemon" ''
    exec ${deno} run --allow-all --node-modules-dir=none ${checkedSrc}/src/main.ts "$@"
  '';

  # Same permissions the repo's own ./af shim uses: the CLI talks to the daemon
  # over localhost, reads request/rubric files a caller points it at, and shells
  # out to docker only for `af volumes`.
  af = pkgs.writeShellScriptBin "af" ''
    exec ${deno} run --quiet --node-modules-dir=none \
      --allow-net --allow-read --allow-env=AGENTFLOW_URL,NO_COLOR --allow-run=docker \
      ${checkedSrc}/cli.ts "$@"
  '';
}
