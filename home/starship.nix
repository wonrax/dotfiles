{ lib, pkgs, ... }:
{
  programs.starship = {
    enable = true;
    enableNushellIntegration = true;
    settings = {
      # https://starship.rs/presets/pure-preset
      format = lib.replaceStrings [ "\n" ] [ "" ] ''
        $username
        $hostname
        $directory
        $cmd_duration
        $python
        ''${custom.jj}
        $line_break
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
      # Grabbed from here
      # https://github.com/acaloiaro/nixos-system/blob/d58081e/common/home-manager/scm/default.nix#L213-L239
      custom = {
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
