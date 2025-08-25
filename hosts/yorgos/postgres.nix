{
  unstablePkgs,
  pkgs,
  lib,
  ...
}:
{
  services.postgresql = {
    enable = true;
    package = unstablePkgs.postgresql_18; # TODO: use stable version when available
    settings = {
      port = 5432;
      listen_addresses = lib.mkForce "*";
    };
    ensureDatabases = [ ];
    authentication = pkgs.lib.mkOverride 10 ''
      #type database  DBuser  auth-method
      local all       all     trust

      # TYPE  DATABASE     USER      ADDRESS        METHOD
      host    all          all       0.0.0.0/0      password
    '';
  };

  networking.firewall.allowedTCPPorts = [
    5432
  ];
}
