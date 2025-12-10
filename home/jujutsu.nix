{ pkgs, user, ... }:
{
  programs.jujutsu = {
    enable = true;
    settings = {
      signing = {
        behavior = "own";
        backend = "ssh";
        key = user.ssh-pub-key;
      };
      # lazily signing only on push
      git.sign-on-push = true;
      user = {
        name = user.username;
        email = user.email;
      };
      aliases.difft = [
        "diff"
        "--tool"
        "difft"
      ];
      merge-tools = {
        difft = {
          program = "${pkgs.difftastic}/bin/difft";
          diff-args = [
            "--color=always"
            "--display"
            "inline"
            "$left"
            "$right"
          ];
        };
      };
      ui = {
        default-command = [ "log" ];
        # FIXME: this doesn't work though, log shows signature unknown
        # https://github.com/jj-vcs/jj/issues/6915#issuecomment-3621860671
        show-cryptographic-signatures = true;
        diff-formatter = ":git"; # so that delta can parse it
        pager = [
          "${pkgs.delta}/bin/delta"
          "--true-color"
          "always"
          "--hunk-header-decoration-style"
          "blue"
          "--width=-2" # use terminal width minus 2
          "--file-style=bold"
          "--file-decoration-style"
          "omit"
          "--line-numbers-right-format"
          "{np} "
          "--line-numbers-left-format"
          "{nm} "
        ];
      };
      colors."diff token" = {
        underline = false;
      };
    };
  };

}
