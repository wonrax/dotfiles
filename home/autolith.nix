{ inputs, pkgs, lib, ... }:
let
  cuaDriver = pkgs.callPackage ../pkgs/cua-driver.nix { };

  # Firecrawl reads its key from the parent environment. Autolith launches stdio
  # servers with a scrubbed environment, so the binding has to be declared here.
  firecrawlServer = ''
    (:name "firecrawl"
     :transport (:type :stdio
                 :command "${pkgs.nodejs}/bin/npx"
                 :arguments ("-y" "firecrawl-mcp")
                 :directory :workspace
                 :environment (("FIRECRAWL_API_KEY" :environment "FIRECRAWL_API_KEY")))
     :approval :prompt)'';

  # --direct keeps the driver in this process tree instead of a daemon, so macOS
  # attributes the Accessibility and Screen Recording grants to the app running
  # Autolith rather than to a separate CuaDriver.app bundle.
  computerUseServer = ''
    (:name "cua-driver"
     :transport (:type :stdio
                 :command "${cuaDriver}/bin/cua-driver"
                 :arguments ("mcp" "--direct")
                 :directory :workspace)
     :approval :prompt)'';

  # Each server block is written flush left and re-indented so the generated
  # file reads like a hand-written sexp.
  indent = text: lib.replaceStrings [ "\n" ] [ "\n " ] text;

  mcpServers =
    map indent (
      [ firecrawlServer ] ++ lib.optional pkgs.stdenv.isDarwin computerUseServer
    );
in
{
  home.packages =
    [ inputs.autolith.packages.${pkgs.stdenv.hostPlatform.system}.default ]
    ++ lib.optional pkgs.stdenv.isDarwin cuaDriver;

  xdg.configFile."autolith/init.lisp".source = ../.config/autolith/init.lisp;
  xdg.configFile."autolith/mcp-deferred.lisp".source =
    ../.config/autolith/mcp-deferred.lisp;

  xdg.configFile."autolith/desktop.lisp".source = ../.config/autolith/desktop.lisp;

  xdg.configFile."autolith/mcp.sexp".text = ''
    (:version 1
     :servers
     (${lib.concatStringsSep "\n  " mcpServers}))
  '';
}
