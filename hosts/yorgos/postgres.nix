{
  pkgs,
  lib,
  ...
}:
{
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_18;
    settings = {
      port = 5432;
      listen_addresses = lib.mkForce "*";
    };
    ensureDatabases = [ ];
    authentication = pkgs.lib.mkOverride 10 ''
      #type database  DBuser  auth-method
      local all       all     peer

      # TYPE  DATABASE     USER      ADDRESS        METHOD
      host    all          all       0.0.0.0/0      password
      # IPv6
      host    all          all       ::/0           password
    '';
    extensions = [ pkgs.postgresql18Packages.pgvector ];
  };

  networking.firewall.allowedTCPPorts = [
    5432
  ];
}
