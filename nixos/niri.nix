{
  config,
  lib,
  user,
  pkgs,
  inputs,
  ...
}:
let
  # Tray: apps register their tray icon once against the StatusNotifierWatcher
  # (owned by the DMS bar / quickshell). If they start first the registration
  # silently drops and the icon never appears. Wait for the watcher to exist.
  waitForTrayThen = pkgs.writeShellScript "wait-for-tray-then" ''
    for _ in $(seq 1 40); do
      ${pkgs.glib}/bin/gdbus call --session --dest org.freedesktop.DBus \
        --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.NameHasOwner org.kde.StatusNotifierWatcher \
        2>/dev/null | grep -q true && break
      sleep 0.25
    done
    exec "$@"
  '';

  # niri-notify-focus: eavesdrops on the notification D-Bus traffic, maps each
  # notification's sender PID to its niri window, and focuses that window when
  # the notification is clicked. Fixes DMS/quickshell not raising the source app
  # (it invokes the action over D-Bus but never passes an activation token, so
  # niri blocks the app's self-raise as focus-stealing). Upstream ships only an
  # AUR package, so we build the single Python script ourselves.
  niri-notify-focus =
    let
      pythonEnv = pkgs.python3.withPackages (ps: [
        ps.dbus-python
        ps.pygobject3
      ]);
    in
    pkgs.stdenvNoCC.mkDerivation {
      pname = "niri-notify-focus";
      version = "0.2.1";
      src = inputs.niri-notify-focus;

      nativeBuildInputs = [
        pkgs.wrapGAppsNoGuiHook
        pkgs.gobject-introspection
      ];
      # glib provides the GLib/GObject typelibs that pygobject loads at runtime;
      # wrapGAppsNoGuiHook wires them onto GI_TYPELIB_PATH in the wrapper.
      buildInputs = [
        pythonEnv
        pkgs.glib
      ];

      dontBuild = true;
      postPatch = ''
        substituteInPlace niri-notify-focus \
          --replace-fail '#!/usr/bin/env python3' '#!${pythonEnv}/bin/python3'
      '';
      installPhase = ''
        runHook preInstall
        install -Dm755 niri-notify-focus $out/bin/niri-notify-focus
        runHook postInstall
      '';
      # The daemon shells out to `niri msg`, so niri must be on its PATH.
      preFixup = ''
        gappsWrapperArgs+=(--prefix PATH : ${lib.makeBinPath [ pkgs.niri ]})
      '';
    };
in
lib.mkIf config.programs.niri.enable {
  environment.systemPackages = with pkgs; [
    xwayland-satellite # for niri xwayland integration
    gpu-screen-recorder-gtk
    vicinae

    papirus-icon-theme
    bibata-cursors
  ];

  home-manager.users.${user.username} = {
    imports = [
      inputs.niri.homeModules.niri
    ];

    systemd.user.services.niri-notify-focus = {
      Unit = {
        Description = "Focus source window on notification click (niri)";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${niri-notify-focus}/bin/niri-notify-focus";
        Restart = "on-failure";
        RestartSec = 5;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    # Background blur for any window with a transparent background. niri 26.04
    # supports `background-effect`, but niri-flake's typed settings can't express
    # it yet (sodiboo/niri-flake#1548), so inject it as a raw KDL fragment and
    # pull it into the config niri actually loads. DMS already turns config.kdl
    # into an include list (keyed `niri-config-dms`) with niri-flake's output
    # retargeted to hm.kdl; mkAfter appends our include after DMS's lines.
    xdg.configFile = {
      "niri/blur.kdl".text = ''
        window-rule {
            background-effect {
                blur true
            }
        }
      '';
      niri-config-dms.text = lib.mkAfter ''
        include "blur.kdl"
      '';
    };

    programs.niri = {
      package = pkgs.niri;
      settings = {
        environment = {
          QT_QPA_PLATFORMTHEME = "gtk3";
          QT_QPA_PLATFORMTHEME_QT6 = "gtk3";
        };
        cursor = {
          theme = "Bibata-Modern-Classic";
        };
        spawn-at-startup = [
          {
            argv = [
              "${waitForTrayThen}"
              "discord"
            ];
          }
          {
            argv = [
              "${waitForTrayThen}"
              "1password"
            ];
          }
          {
            argv = [
              "${waitForTrayThen}"
              "Telegram"
            ];
          }
          {
            argv = [
              "${waitForTrayThen}"
              "spotify"
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
          focus-ring = {
            width = 2;
            # Deep teal (~0.23 relative luminance): sits in the narrow band that
            # clears 3:1 contrast against both the dark and light DMS theme
            # backgrounds. A wider/brighter teal washes out in light mode.
            active.color = "#0d9488";
          };
          gaps = 4;
        };
        # Recede inactive windows. niri has no darkening "dim", only opacity, so
        # this makes unfocused windows slightly see-through rather than darker.
        window-rules = [
          {
            matches = [ { is-active = false; } ];
            opacity = 0.85;
          }
        ];
        prefer-no-csd = true;
        input = {
          keyboard = {
            repeat-rate = 50;
          };
          mouse = {
            accel-speed = 1;
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
          "Super+Shift+S" = lib.mkDefault { action.screenshot = { }; };

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
