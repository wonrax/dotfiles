# TODO: enable nix periodic GC
# TODO: enable swap
# TODO: reorganize modules and their dependencies so that they are easier to
# manage

{
  inputs,
  user,
  home-manager,
  unstablePkgs,
  ...
}:
[
  (
    # System config
    { pkgs, ... }:
    {
      nixpkgs.config.allowUnfree = true;

      environment.systemPackages = with pkgs; [
        vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
        git
        gnome-tweaks
        xclip
        unzip
        tmux

        kitty # required for the default Hyprland config
      ];

      programs.hyprland.enable = true;

      # Enable docker
      virtualisation.docker.enable = true;

      users.users.${user.username} = {
        isNormalUser = true;
        description = user.fullname;
        extraGroups = [
          "networkmanager"
          "wheel"
        ];

        packages = with pkgs; [
          google-chrome
          tailscale-systray
          jetbrains.datagrip

          lazydocker

          # NOTE: These packages are NixOS specific because on macOS I'd like
          # for these programs to be able to update itself, which is only
          # possible if you install them the "normal" way.
          # - entertainment
          spotify
          plex-desktop
          # - communication
          discord
        ];
      };

      programs._1password.enable = true;
      programs._1password-gui = {
        enable = true;
        # Certain features, including CLI integration and system authentication
        # support, require enabling PolKit integration on some desktop
        # environments (e.g. Plasma).
        polkitPolicyOwners = [ user.username ];
      };

      i18n.inputMethod = {
        enable = true;
        type = "ibus";
        ibus.engines = with pkgs.ibus-engines; [
          bamboo
        ];
      };

      # NixOS does not follow the XDG Base Directory Specification by default
      # Tracking issue: https://github.com/NixOS/nixpkgs/issues/224525
      environment.variables = {
        XDG_CACHE_HOME = "$HOME/.cache";
        XDG_CONFIG_DIRS = "/etc/xdg";
        XDG_CONFIG_HOME = "$HOME/.config";
        XDG_DATA_HOME = "$HOME/.local/share";
        XDG_STATE_HOME = "$HOME/.local/state";
      };
    }
  )

  (
    # Gnome extensions
    { pkgs, ... }:
    {
      environment.systemPackages = with pkgs.gnomeExtensions; [
        tray-icons-reloaded
        user-themes
        dash-to-dock
      ];

    }
  )

  # Keyboard remapping
  inputs.xremap-flake.nixosModules.default
  {
    # This configures the service to only run for a specific user
    services.xremap = {
      /*
        NOTE: since this sample configuration does not have any DE,
        xremap needs to be started manually by systemctl --user start xremap
      */
      serviceMode = "user";
      userName = user.username;
    };
    # Modmap for single key rebinds
    services.xremap.config.modmap = [
      {
        name = "Global";
        remap = {
          "CapsLock" = "Esc";
        }; # globally remap CapsLock to Esc
      }
    ];
  }

  # make home-manager as a module of nixos
  # so that home-manager configuration will be deployed automatically when executing `nixos-rebuild switch`
  home-manager.nixosModules.home-manager
  {
    home-manager.useUserPackages = true;
    home-manager.extraSpecialArgs = {
      inherit user unstablePkgs;
    };
    home-manager.users.${user.username} = {
      imports = [
        ./home.nix
        (
          { pkgs, config, ... }:
          let
            rofi-launchers = pkgs.callPackage ./rofi.nix { };
          in
          {
            home.packages = with pkgs; [
              rofi
              rofi-launchers.package
              rofi-launchers.launch
            ];

            dconf.settings = {
              "org/gnome/settings-daemon/plugins/media-keys" = {
                custom-keybindings = [
                  "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/"
                ];
              };
              "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" = {
                # Super + Space
                # NOTE: if this does not work, try disabling the default
                # binding (likely input switching) in the GNOME settings and
                # then re-switch configuration
                binding = "<Super>space";
                command = pkgs.lib.getExe rofi-launchers.launch;
                name = "Launch ulauncher";
              };
            };

            # TODO: also config SSH for 1password, see example in:
            # https://github.com/cbr9/dotfiles/blob/617144/modules/home-manager/ssh/default.nix
            programs.git = {
              extraConfig = {
                gpg.ssh.program = "${pkgs._1password-gui}/bin/op-ssh-sign";
              };
            };

            nixpkgs.overlays = [ inputs.hyprpanel.overlay ];
            wayland.windowManager.hyprland = {
              enable = true;
              settings = {
                exec-once = [
                  "${pkgs.hyprpanel}/bin/hyprpanel"
                ];
                "$terminal" = "${pkgs.ghostty}/bin/ghostty";
                "$menu" = "${rofi-launchers.launch}/bin/rofi-launcher";
              };
              extraConfig = ''
                ################
                ### MONITORS ###
                ################

                # See https://wiki.hyprland.org/Configuring/Monitors/
                monitor=,preferred,auto,1.066667

                ###################
                ### MY PROGRAMS ###
                ###################

                # See https://wiki.hyprland.org/Configuring/Keywords/
                $fileManager = dolphin

                #################
                ### AUTOSTART ###
                #################

                # Autostart necessary processes (like notifications daemons, status bars, etc.)
                # Or execute your favorite apps at launch like this:

                # exec-once = $terminal

                #############################
                ### ENVIRONMENT VARIABLES ###
                #############################

                # See https://wiki.hyprland.org/Configuring/Environment-variables/

                env = XCURSOR_SIZE,24
                env = HYPRCURSOR_SIZE,24
                env = NIXOS_OZONE_WL,1
                env = LIBVA_DRIVER_NAME,nvidia
                env = __GLX_VENDOR_LIBRARY_NAME,nvidia

                ###################
                ### PERMISSIONS ###
                ###################

                # See https://wiki.hyprland.org/Configuring/Permissions/
                # Please note permission changes here require a Hyprland restart and are not applied on-the-fly
                # for security reasons

                # ecosystem {
                #   enforce_permissions = 1
                # }

                # permission = /usr/(bin|local/bin)/grim, screencopy, allow
                # permission = /usr/(lib|libexec|lib64)/xdg-desktop-portal-hyprland, screencopy, allow
                # permission = /usr/(bin|local/bin)/hyprpm, plugin, allow

                #####################
                ### LOOK AND FEEL ###
                #####################

                # Refer to https://wiki.hyprland.org/Configuring/Variables/

                # https://wiki.hyprland.org/Configuring/Variables/#general
                general {
                    gaps_in = 5
                    gaps_out = 20

                    border_size = 2

                    # https://wiki.hyprland.org/Configuring/Variables/#variable-types for info about colors
                    col.active_border = rgba(33ccffee) rgba(00ff99ee) 45deg
                    col.inactive_border = rgba(595959aa)

                    # Set to true enable resizing windows by clicking and dragging on borders and gaps
                    resize_on_border = false

                    # Please see https://wiki.hyprland.org/Configuring/Tearing/ before you turn this on
                    allow_tearing = false

                    layout = dwindle
                }

                # https://wiki.hyprland.org/Configuring/Variables/#decoration
                decoration {
                    rounding = 10
                    # rounding_power = 2 # TODO: not available on nixpkgs stable yet

                    # Change transparency of focused and unfocused windows
                    active_opacity = 1.0
                    inactive_opacity = 1.0

                    shadow {
                        enabled = true
                        range = 4
                        render_power = 3
                        color = rgba(1a1a1aee)
                    }

                    # https://wiki.hyprland.org/Configuring/Variables/#blur
                    blur {
                        enabled = true
                        size = 3
                        passes = 1

                        vibrancy = 0.1696
                    }
                }

                # https://wiki.hyprland.org/Configuring/Variables/#animations
                animations {
                    enabled = yes, please :)

                    # Default animations, see https://wiki.hyprland.org/Configuring/Animations/ for more

                    bezier = easeOutQuint,0.23,1,0.32,1
                    bezier = easeInOutCubic,0.65,0.05,0.36,1
                    bezier = linear,0,0,1,1
                    bezier = almostLinear,0.5,0.5,0.75,1.0
                    bezier = quick,0.15,0,0.1,1

                    animation = global, 1, 10, default
                    animation = border, 1, 5.39, easeOutQuint
                    animation = windows, 1, 4.79, easeOutQuint
                    animation = windowsIn, 1, 4.1, easeOutQuint, popin 87%
                    animation = windowsOut, 1, 1.49, linear, popin 87%
                    animation = fadeIn, 1, 1.73, almostLinear
                    animation = fadeOut, 1, 1.46, almostLinear
                    animation = fade, 1, 3.03, quick
                    animation = layers, 1, 3.81, easeOutQuint
                    animation = layersIn, 1, 4, easeOutQuint, fade
                    animation = layersOut, 1, 1.5, linear, fade
                    animation = fadeLayersIn, 1, 1.79, almostLinear
                    animation = fadeLayersOut, 1, 1.39, almostLinear
                    animation = workspaces, 1, 1.94, almostLinear, fade
                    animation = workspacesIn, 1, 1.21, almostLinear, fade
                    animation = workspacesOut, 1, 1.94, almostLinear, fade
                }

                # Ref https://wiki.hyprland.org/Configuring/Workspace-Rules/
                # "Smart gaps" / "No gaps when only"
                # uncomment all if you wish to use that.
                # workspace = w[tv1], gapsout:0, gapsin:0
                # workspace = f[1], gapsout:0, gapsin:0
                # windowrule = bordersize 0, floating:0, onworkspace:w[tv1]
                # windowrule = rounding 0, floating:0, onworkspace:w[tv1]
                # windowrule = bordersize 0, floating:0, onworkspace:f[1]
                # windowrule = rounding 0, floating:0, onworkspace:f[1]

                # See https://wiki.hyprland.org/Configuring/Dwindle-Layout/ for more
                dwindle {
                    pseudotile = true # Master switch for pseudotiling. Enabling is bound to mainMod + P in the keybinds section below
                    preserve_split = true # You probably want this
                }

                # See https://wiki.hyprland.org/Configuring/Master-Layout/ for more
                master {
                    new_status = master
                }

                # https://wiki.hyprland.org/Configuring/Variables/#misc
                misc {
                    force_default_wallpaper = -1 # Set to 0 or 1 to disable the anime mascot wallpapers
                    disable_hyprland_logo = false # If true disables the random hyprland logo / anime girl background. :(
                }


                #############
                ### INPUT ###
                #############

                # https://wiki.hyprland.org/Configuring/Variables/#input
                input {
                    kb_layout = us
                    kb_variant =
                    kb_model =
                    kb_options =
                    kb_rules =

                    follow_mouse = 1

                    sensitivity = 0 # -1.0 - 1.0, 0 means no modification.

                    touchpad {
                        natural_scroll = false
                    }
                }

                # https://wiki.hyprland.org/Configuring/Variables/#gestures
                gestures {
                    workspace_swipe = false
                }

                # Example per-device config
                # See https://wiki.hyprland.org/Configuring/Keywords/#per-device-input-configs for more
                device {
                    name = epic-mouse-v1
                    sensitivity = -0.5
                }


                ###################
                ### KEYBINDINGS ###
                ###################

                # See https://wiki.hyprland.org/Configuring/Keywords/
                $mainMod = SUPER # Sets "Windows" key as main modifier

                # Example binds, see https://wiki.hyprland.org/Configuring/Binds/ for more
                bind = $mainMod, Q, exec, $terminal
                bind = $mainMod, C, killactive,
                bind = $mainMod, M, exit,
                bind = $mainMod, E, exec, $fileManager
                bind = $mainMod, V, togglefloating,
                bind = $mainMod, R, exec, $menu
                bind = $mainMod, P, pseudo, # dwindle
                bind = $mainMod, J, togglesplit, # dwindle

                # Move focus with mainMod + arrow keys
                bind = $mainMod, left, movefocus, l
                bind = $mainMod, right, movefocus, r
                bind = $mainMod, up, movefocus, u
                bind = $mainMod, down, movefocus, d

                # Switch workspaces with mainMod + [0-9]
                bind = $mainMod, 1, workspace, 1
                bind = $mainMod, 2, workspace, 2
                bind = $mainMod, 3, workspace, 3
                bind = $mainMod, 4, workspace, 4
                bind = $mainMod, 5, workspace, 5
                bind = $mainMod, 6, workspace, 6
                bind = $mainMod, 7, workspace, 7
                bind = $mainMod, 8, workspace, 8
                bind = $mainMod, 9, workspace, 9
                bind = $mainMod, 0, workspace, 10

                # Move active window to a workspace with mainMod + SHIFT + [0-9]
                bind = $mainMod SHIFT, 1, movetoworkspace, 1
                bind = $mainMod SHIFT, 2, movetoworkspace, 2
                bind = $mainMod SHIFT, 3, movetoworkspace, 3
                bind = $mainMod SHIFT, 4, movetoworkspace, 4
                bind = $mainMod SHIFT, 5, movetoworkspace, 5
                bind = $mainMod SHIFT, 6, movetoworkspace, 6
                bind = $mainMod SHIFT, 7, movetoworkspace, 7
                bind = $mainMod SHIFT, 8, movetoworkspace, 8
                bind = $mainMod SHIFT, 9, movetoworkspace, 9
                bind = $mainMod SHIFT, 0, movetoworkspace, 10

                # Example special workspace (scratchpad)
                bind = $mainMod, S, togglespecialworkspace, magic
                bind = $mainMod SHIFT, S, movetoworkspace, special:magic

                # Scroll through existing workspaces with mainMod + scroll
                bind = $mainMod, mouse_down, workspace, e+1
                bind = $mainMod, mouse_up, workspace, e-1

                # Move/resize windows with mainMod + LMB/RMB and dragging
                bindm = $mainMod, mouse:272, movewindow
                bindm = $mainMod, mouse:273, resizewindow

                # Laptop multimedia keys for volume and LCD brightness
                bindel = ,XF86AudioRaiseVolume, exec, wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+
                bindel = ,XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
                bindel = ,XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
                bindel = ,XF86AudioMicMute, exec, wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle
                bindel = ,XF86MonBrightnessUp, exec, brightnessctl -e4 -n2 set 5%+
                bindel = ,XF86MonBrightnessDown, exec, brightnessctl -e4 -n2 set 5%-

                # Requires playerctl
                bindl = , XF86AudioNext, exec, playerctl next
                bindl = , XF86AudioPause, exec, playerctl play-pause
                bindl = , XF86AudioPlay, exec, playerctl play-pause
                bindl = , XF86AudioPrev, exec, playerctl previous

                ##############################
                ### WINDOWS AND WORKSPACES ###
                ##############################

                # See https://wiki.hyprland.org/Configuring/Window-Rules/ for more
                # See https://wiki.hyprland.org/Configuring/Workspace-Rules/ for workspace rules

                # Example windowrule
                # windowrule = float,class:^(kitty)$,title:^(kitty)$

                # Ignore maximize requests from apps. You'll probably like this.
                windowrule = suppressevent maximize, class:.*

                # Fix some dragging issues with XWayland
                windowrule = nofocus,class:^$,title:^$,xwayland:1,floating:1,fullscreen:0,pinned:0
              '';
            };
          }
        )
      ];
    };
  }

  (
    # Systemd services
    { pkgs, ... }:
    {
      users.users.${user.username}.extraGroups = [ "docker" ];

      # ==== Tailscale ====
      services.tailscale.enable = true;
      systemd.user.services.tailscale-systray = {
        enable = true;
        wantedBy = [
          "graphical-session.target"
          "multi-user.target"
        ];
        after = [ "graphical-session.target" ];
        path = with pkgs; [
          tailscale
          xdg-utils
          xclip
        ];
        serviceConfig = {
          ExecStart = pkgs.lib.getExe pkgs.tailscale-systray;
          Restart = "on-failure";
          RestartSec = "3";
        };
      };
      # https://github.com/tailscale/tailscale/issues/4432#issuecomment-1112819111
      networking.firewall.checkReversePath = "loose";

      # ==== Ulauncher ====
      # TODO: find a way to group all things related to a module (e.g.
      # ulauncher) into a single module and not spread them across multiple
      # modules
      systemd.user.services."net.launchpad.ulauncher" = {
        enable = false; # Disabled because we're using rofi instead
        wantedBy = [
          "graphical-session.target"
          "multi-user.target"
        ];
        after = [ "graphical-session.target" ];
        environment = {
          GDK_BACKEND = "x11";
        };
        serviceConfig = {
          Type = "dbus";
          BusName = "io.ulauncher.Ulauncher";
          # A hack to fix ulauncher unable to find the installed apps
          # https://github.com/NixOS/nixpkgs/issues/214668#issuecomment-1722569860
          ExecStart = pkgs.writeShellScript "ulauncher-env-wrapper.sh" ''
            export PATH="''${XDG_BIN_HOME}:$HOME/.nix-profile/bin:/etc/profiles/per-user/$USER/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin"
            exec ${pkgs.ulauncher}/bin/ulauncher --hide-window
          '';
          Restart = "on-failure";
          RestartSec = "1";
        };
      };
    }
  )

  (
    # Globally linked libraries using nix-ld
    { pkgs, ... }:
    {
      programs.nix-ld.enable = true;
      programs.nix-ld.libraries = with pkgs; [
        libxkbcommon

        # currently only neovim's smart open depends on this
        sqlite

        # libGL
        # wayland
      ];
      environment.variables = {
        # Register the nix-ld library path
        LD_LIBRARY_PATH = "$LD_LIBRARY_PATH:$NIX_LD_LIBRARY_PATH";
      };
    }
  )
]
