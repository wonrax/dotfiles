{
  config,
  lib,
  user,
  pkgs,
  inputs,
  ...
}:
lib.mkIf config.programs.niri.enable {
  environment.systemPackages = with pkgs; [
    xwayland-satellite # for niri xwayland integration
    gpu-screen-recorder-gtk
    vicinae
    papirus-icon-theme
  ];

  home-manager.users.${user.username} = {
    imports = [
      inputs.niri.homeModules.niri
    ];

    programs.niri = {
      package = pkgs.niri;
      settings = {
        environment = {
          QT_QPA_PLATFORMTHEME = "gtk3";
          QT_QPA_PLATFORMTHEME_QT6 = "gtk3";
        };
        spawn-at-startup = [
          {
            argv = [
              "sh"
              "-c"
              "sleep 3 && discord"
            ];
          }
          {
            argv = [
              "sh"
              "-c"
              "sleep 3 && 1password"
            ];
          }
          {
            argv = [
              "sh"
              "-c"
              "sleep 3 && Telegram"
            ];
          }
          {
            argv = [
              "sh"
              "-c"
              "sleep 3 && spotify"
            ];
          }
          {
            argv = [
              "vicinae"
              "server"
            ];
          }
        ];
        layout = {
          focus-ring.width = 3;
          gaps = 8;
        };
        prefer-no-csd = true;
        input = {
          keyboard = {
            repeat-rate = 50;
          };
          mouse = {
            accel-speed = -0.5;
            accel-profile = "adaptive";
          };
        };
        gestures.hot-corners.enable = false;
        binds = {
          "Mod+Shift+Slash".action.show-hotkey-overlay = { };

          "Alt+Space".action.spawn = [
            "vicinae"
            "toggle"
          ];

          "Mod+Space".action.spawn = [
            "fcitx5-remote"
            "-t"
          ];

          "Mod+T".action.spawn = "ghostty";

          # Volume keys mappings for PipeWire & WirePlumber.
          # The allow-when-locked=true property makes them work even when the session is locked.
          "XF86AudioRaiseVolume" = {
            allow-when-locked = true;
            action.spawn = [
              "wpctl"
              "set-volume"
              "@DEFAULT_AUDIO_SINK@"
              "0.05+"
            ];
          };
          "XF86AudioLowerVolume" = {
            allow-when-locked = true;
            action.spawn = [
              "wpctl"
              "set-volume"
              "@DEFAULT_AUDIO_SINK@"
              "0.05-"
            ];
          };
          "XF86AudioMute" = {
            allow-when-locked = true;
            action.spawn = [
              "wpctl"
              "set-mute"
              "@DEFAULT_AUDIO_SINK@"
              "toggle"
            ];
          };
          "XF86AudioMicMute" = {
            allow-when-locked = true;
            action.spawn = [
              "wpctl"
              "set-mute"
              "@DEFAULT_AUDIO_SOURCE@"
              "toggle"
            ];
          };

          "Mod+Q".action.close-window = { };

          "Mod+H".action.focus-column-left = { };
          "Mod+L".action.focus-column-right = { };
          "Mod+Ctrl+H".action.move-column-left = { };
          "Mod+Ctrl+L".action.move-column-right = { };

          "Mod+J".action.focus-window-or-workspace-down = { };
          "Mod+K".action.focus-window-or-workspace-up = { };
          "Mod+Ctrl+J".action.move-window-down-or-to-workspace-down = { };
          "Mod+Ctrl+K".action.move-window-up-or-to-workspace-up = { };
          "Mod+Shift+J".action.move-workspace-down = { };
          "Mod+Shift+K".action.move-workspace-up = { };

          "Mod+Home".action.focus-column-first = { };
          "Mod+End".action.focus-column-last = { };
          "Mod+Ctrl+Home".action.move-column-to-first = { };
          "Mod+Ctrl+End".action.move-column-to-last = { };

          "Mod+Shift+Left".action.focus-monitor-left = { };
          "Mod+Shift+Down".action.focus-monitor-down = { };
          "Mod+Shift+Up".action.focus-monitor-up = { };
          "Mod+Shift+Right".action.focus-monitor-right = { };

          "Mod+WheelScrollDown" = {
            cooldown-ms = 150;
            action.focus-workspace-down = { };
          };
          "Mod+WheelScrollUp" = {
            cooldown-ms = 150;
            action.focus-workspace-up = { };
          };
          "Mod+Ctrl+WheelScrollDown" = {
            cooldown-ms = 150;
            action.move-column-to-workspace-down = { };
          };
          "Mod+Ctrl+WheelScrollUp" = {
            cooldown-ms = 150;
            action.move-column-to-workspace-up = { };
          };

          "Mod+WheelScrollRight".action.focus-column-right = { };
          "Mod+WheelScrollLeft".action.focus-column-left = { };
          "Mod+Ctrl+WheelScrollRight".action.move-column-right = { };
          "Mod+Ctrl+WheelScrollLeft".action.move-column-left = { };

          # Usually scrolling up and down with Shift in applications results in
          # horizontal scrolling; these binds replicate that.
          "Mod+Shift+WheelScrollDown".action.focus-column-right = { };
          "Mod+Shift+WheelScrollUp".action.focus-column-left = { };
          "Mod+Ctrl+Shift+WheelScrollDown".action.move-column-right = { };
          "Mod+Ctrl+Shift+WheelScrollUp".action.move-column-left = { };

          "Mod+Comma".action.consume-window-into-column = { };
          "Mod+Period".action.expel-window-from-column = { };

          "Mod+R".action.switch-preset-column-width = { };
          "Mod+Shift+R".action.reset-window-height = { };
          "Mod+F".action.maximize-column = { };
          "Mod+Shift+F".action.fullscreen-window = { };
          "Mod+C".action.center-column = { };

          "Mod+Minus".action.set-column-width = "-10%";
          "Mod+Equal".action.set-column-width = "+10%";

          "Mod+Shift+Minus".action.set-window-height = "-10%";
          "Mod+Shift+Equal".action.set-window-height = "+10%";

          "Print".action.screenshot = { };
          "Ctrl+Print".action.screenshot-screen = { };
          "Alt+Print".action.screenshot-window = { };
          "Super+Shift+S".action.screenshot = { };

          # The quit action will show a confirmation dialog to avoid accidental exits.
          "Mod+Shift+E".action.quit = { };

          # Powers off the monitors. To turn them back on, do any input like
          # moving the mouse or pressing any other key.
          "Mod+Shift+P".action.power-off-monitors = { };
        };
      };
    };
  };
}
