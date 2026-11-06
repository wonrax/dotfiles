{ pkgs }:
pkgs.buildNpmPackage {
  pname = "moneylover-mcp";
  version = "0.0.3";
  src = pkgs.fetchzip {
    url = "https://github.com/ferdhika31/moneylover-mcp/archive/dc54560b4e0e327065b0989b05620addf5dac579.tar.gz";
    hash = "sha256-0fvkTgMtPWoMhZ5IagvG+cpPkeUDVeb1o7Vi889irF4=";
  };
  npmDepsHash = "sha256-VTM3YudpBlsK3S8kV0uzjTUoyJVx6m80ETAAnRQeL7s=";
  dontNpmBuild = true;
  patches = [ ./moneylover-auth-refresh.patch ];
  postPatch = ''
    cp ${./test_moneylover_auth.mjs} tests/auth-refresh.mjs
  '';
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    npm test
    node --test tests/auth-refresh.mjs
    runHook postCheck
  '';
}
