{ pkgs, user, ... }:
{
  programs.git = {
    enable = true;
    settings = {
      user.name = user.username;
      user.email = user.email;
      user.signingKey = user.ssh-pub-key;

      pull.rebase = false;
      pull.ff = true;

      merge.conflictStyle = "diff3";

      commit.gpgsign = true;
      gpg.format = "ssh";

      # diff.tool selects difft as `git diff`'s engine; difftool.difftastic.cmd
      # wires up `git difftool` (aliased to `git dft`); pager.difftool pipes
      # difftool output through delta. core.pager runs delta on `git log/show`.
      diff = {
        colorMoved = "default";
        tool = "${pkgs.difftastic}/bin/difft";
      };
      difftool = {
        prompt = false;
        difftastic.cmd = "${pkgs.difftastic}/bin/difft '$LOCAL' '$REMOTE'";
      };
      pager.difftool = true;
      alias.dft = "difftool";

      core.pager = "${pkgs.delta}/bin/delta";
      interactive.diffFilter = "${pkgs.delta}/bin/delta --color-only --detect-dark-light always";
      delta = {
        navigate = true;
        line-numbers = true;
      };
    };
  };
}
