# NixOS-WSL host (work laptop, Windows user `hai.ha`).
#
# Builds on the headless ../../nixos/core only; the GUI apps, desktop session
# and hardware bits in ../../nixos/desktop stay with peggy. Windows Terminal is
# the terminal.
#
# 1Password runs on the Windows side, so the integrations go through Windows:
#   - SSH agent: wsl2-ssh-agent relays the Windows `openssh-ssh-agent` named
#     pipe (served by 1Password once "Use the SSH agent" is turned on in
#     Settings -> Developer) to ~/.1password/agent.sock. That is the same path
#     IdentityAgent points at on Linux in home/common.nix, so ssh, git and jj
#     work without anything WSL-specific in the shared config.
#   - Commit signing: op-ssh-sign-wsl.exe, 1Password's WSL signing helper.
{
  inputs,
  lib,
  pkgs,
  user,
  ...
}:
let
  windowsUser = "hai.ha";
  windowsHome = "/mnt/c/Users/${windowsUser}";
  # App execution alias installed by the Microsoft Store build of 1Password.
  opSshSign = "${windowsHome}/AppData/Local/Microsoft/WindowsApps/op-ssh-sign-wsl.exe";

  # Work GitHub account. Repos under ~/work commit, sign and push as it;
  # everything else stays on the personal identity from flake.nix.
  work = {
    name = "Hai Ha";
    email = "hai.ha@opswat.com";
    # 1password "opswat-ssh-key"
    ssh-pub-key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFwcwqCJewutubPA1brWqVNVLqlu1PWoEAauA7bJhq6S";
    sshHost = "github-work";
  };
in
{
  imports = [
    inputs.nixos-wsl.nixosModules.default
    ../../nixos/core
    ../../nixos/mdcore.nix
    ./rex.nix
  ];

  # MetaDefender Core, repackaged from the deb. Web UI on http://localhost:8008.
  services.mdcore.enable = true;

  wsl = {
    enable = true;
    defaultUser = user.username;
    # Keep Windows tools (code, explorer.exe, clip.exe, ...) on PATH.
    interop.includePath = true;
  };

  networking.hostName = "opswat-wsl";

  # Deploys to pumpkin build its aarch64 closure here.
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  users.users.${user.username}.shell = pkgs.nushell;
  environment.shells = [ pkgs.nushell ];

  # This distro joins the tailnet as its own node, so other devices can reach
  # it with `ssh wonrax@opswat-wsl` through Tailscale SSH. First login is
  # interactive: `sudo tailscale up` (the --ssh flag below is applied by
  # tailscaled-set.service on every boot).
  services.tailscale.extraSetFlags = [ "--ssh" ];

  home-manager.users.${user.username} =
    { config, ... }:
    {
      programs.git.settings.gpg.ssh.program = opSshSign;
      programs.jujutsu.settings.signing.backends.ssh.program = opSshSign;

      # GitHub picks the account from whichever key authenticates first, and
      # the 1Password agent offers every key it holds. Pinning a public key
      # with IdentitiesOnly makes the agent sign with that key alone.
      home.file.".ssh/github-personal.pub".text = user.ssh-pub-key;
      home.file.".ssh/github-work.pub".text = work.ssh-pub-key;
      programs.ssh.settings = {
        "github.com" = {
          IdentityFile = "~/.ssh/github-personal.pub";
          IdentitiesOnly = "yes";
        };
        ${work.sshHost} = {
          HostName = "github.com";
          User = "git";
          IdentityFile = "~/.ssh/github-work.pub";
          IdentitiesOnly = "yes";
        };
      };

      # Clone work repos into ~/work with `git@github-work:<org>/<repo>`.
      # Inside ~/work, github.com remotes are rewritten to the work alias too.
      programs.git.includes = [
        {
          condition = "gitdir:~/work/";
          contents = {
            user.name = work.name;
            user.email = work.email;
            user.signingKey = work.ssh-pub-key;
            url."git@${work.sshHost}:".insteadOf = "git@github.com:";
          };
        }
      ];
      programs.jujutsu.settings."--scope" = [
        {
          "--when".repositories = [ "${config.home.homeDirectory}/work" ];
          user.name = work.name;
          user.email = work.email;
          signing.key = work.ssh-pub-key;
        }
      ];

      # Relay 1Password's Windows SSH agent to the socket IdentityAgent uses.
      systemd.user.services."1password-ssh-agent-bridge" = {
        Unit.Description = "Relay the Windows 1Password SSH agent into WSL";
        Service = {
          ExecStartPre = "${pkgs.coreutils}/bin/rm -f %h/.1password/agent.sock";
          ExecStart = lib.concatStringsSep " " [
            (lib.getExe pkgs.wsl2-ssh-agent)
            "-foreground"
            "-socket %h/.1password/agent.sock"
            "-powershell-path /mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe"
          ];
          Restart = "on-failure";
          RestartSec = 3;
        };
        Install.WantedBy = [ "default.target" ];
      };
      home.file.".1password/.keep".text = "";

      home.sessionVariables.SSH_AUTH_SOCK = "${config.home.homeDirectory}/.1password/agent.sock";

      home.stateVersion = "26.05";
    };

  system.stateVersion = "26.05";
}
