config:
let
  rex = config.services.rex;
  login = rex.loginServer;
  policy = builtins.fromJSON config.environment.etc."rex/accounts.jsonc".text;
  principal = "tailscale:hahuylonghai2012@gmail.com";
in
assert login.enable;
assert !rex.enable;
assert login.pam;
assert !login.allowAnonymous;
assert login.accountsFile == null;
assert
  policy == {
    version = 1;
    accounts.wonrax.principals = [ principal ];
    defaults.${principal} = "wonrax";
  };
assert login.extraListen == [ "tailnet://:7297" ];
assert !login.tailscaleServe.enable;
assert !rex.tailscale.enable;
assert builtins.elem 7297 config.networking.firewall.interfaces.tailscale0.allowedTCPPorts;
assert !(builtins.elem 7297 config.networking.firewall.allowedTCPPorts);
assert builtins.all (
  range: range.from > 7297 || range.to < 7297
) config.networking.firewall.allowedTCPPortRanges;
true
