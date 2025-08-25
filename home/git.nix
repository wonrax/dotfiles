{ pkgs, user, ... }:
{
  programs.git = {
    enable = true;
    userName = user.username;
    userEmail = user.email;
    extraConfig = {
      user.signingKey = user.ssh-pub-key;

      pull.rebase = false;
      pull.ff = true;

      merge.conflictStyle = "diff3";

      # enable gpg signing
      commit.gpgsign = true;
      gpg.format = "ssh";

      # TODO: what are all these difftool doing with each other?

      diff = {
        colorMoved = "default";
        tool = "${pkgs.difftastic}/bin/difft";
      };

      difftool = {
        prompt = false;
        difftastic = {
          cmd = "${pkgs.difftastic}/bin/difft '$LOCAL' '$REMOTE'";
        };
      };

      pager.difftool = true;
      alias.dft = "difftool";

      core.pager = "${pkgs.delta}/bin/delta";
      interactive.diffFilter = "${pkgs.delta}/bin/delta --color-only";
      delta = {
        navigate = true;
        line-numbers = true;
      };
    };
  };

}
