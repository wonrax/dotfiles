{ lib, pkgs, ... }:
let
  prompt-info = pkgs.stdenv.mkDerivation {
    pname = "prompt-info";
    version = "1.0.0";
    src = ./prompt-info.zig;
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.zig ];
    buildPhase = ''
      export XDG_CACHE_HOME="$TMPDIR/zig-cache"
      mkdir -p "$XDG_CACHE_HOME"
      zig build-exe $src -O ReleaseFast -fno-error-tracing --name prompt-info
    '';
    installPhase = ''
      mkdir -p $out/bin
      cp prompt-info $out/bin/
    '';
  };

  fetch-starship-prompt-info = pkgs.writeShellScriptBin "fetch-starship-prompt-info" ''
    ${pkgs.nushell}/bin/nu ${./fetch-starship-prompt-info.nu}
  '';
in
{
  home.packages = [ fetch-starship-prompt-info ];

  programs.starship = {
    enable = true;
    enableNushellIntegration = true;
    settings = {
      # https://starship.rs/presets/pure-preset
      format = lib.replaceStrings [ "\n" ] [ "" ] ''
        ''${custom.memory}
        $line_break
        $time
        ''${custom.uptime}
        ''${custom.rotating}
        $line_break
        $username
        $hostname
        $directory
        $cmd_duration
        $python
        ''${custom.jj}
        $line_break
        $nix_shell
        $character'';
      directory.style = "bold cyan";
      character = {
        format = "$symbol";
        success_symbol = "[>](blue)";
        error_symbol = "[>](red)";
      };
      cmd_duration = {
        format = "[$duration]($style) ";
        style = "yellow";
      };
      python = {
        format = "[$virtualenv]($style) ";
        style = "bright-black";
      };
      time = {
        disabled = false;
        format = "[$time]($style) ";
        style = "bold blue";
        time_format = "%H:%M:%S";
      };
      custom = {
        uptime = {
          shell = [
            "${prompt-info}/bin/prompt-info"
            "--uptime"
          ];
          use_stdin = false;
          format = "[\\[$output session\\]]($style) ";
          style = "bright-blue";
          when = true;
          os = "macos";
        };
        memory = {
          shell = [
            "${prompt-info}/bin/prompt-info"
            "--memory"
          ];
          use_stdin = false;
          format = "[MEM $output]($style) ";
          style = "bright-black";
          when = true;
        };
        rotating = {
          shell = [
            "${prompt-info}/bin/prompt-info"
            "--rotating"
          ];
          use_stdin = false;
          format = "[$output]($style) ";
          style = "bright-black";
          when = true;
        };
        jj = {
          command = "prompt";
          ignore_timeout = true;
          shell = [
            (lib.getExe pkgs.starship-jj)
            "--ignore-working-copy"
            "starship"
          ];
          use_stdin = false;
          when = true;
        };
      };
    };
  };
}
