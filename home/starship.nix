{ lib, ... }:
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
    };
  };

}
