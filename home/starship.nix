{ lib, pkgs, ... }:
let
  memory-script = pkgs.writeShellScript "starship-memory" ''
    if [ "$(uname)" = "Darwin" ]; then
      pagesize=$(sysctl -n hw.pagesize)
      total=$(sysctl -n hw.memsize)
      vm_stat | awk -v ps="$pagesize" -v t="$total" '
        /Pages active/ {a=$3}
        /Pages wired/ {w=$4}
        /occupied by compressor/ {c=$5}
        END {
          gsub(/\./, "", a); gsub(/\./, "", w); gsub(/\./, "", c)
          used = (a + w + c) * ps
          printf "%.1f/%.0fGB", used/1024/1024/1024, t/1024/1024/1024
        }'
    else
      awk '/MemTotal/ {t=$2} /MemAvailable/ {a=$2} END {printf "%.1f/%.0fGB", (t-a)/1024/1024, t/1024/1024}' /proc/meminfo
    fi
  '';
in
{
  programs.starship = {
    enable = true;
    enableNushellIntegration = true;
    settings = {
      # https://starship.rs/presets/pure-preset
      format = lib.replaceStrings [ "\n" ] [ "" ] ''
        $time
        ''${custom.memory}
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
        style = "bold-blue";
        time_format = "%H:%M:%S";
      };
      custom = {
        memory = {
          command = "${memory-script}";
          format = "[MEM $output]($style) ";
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
