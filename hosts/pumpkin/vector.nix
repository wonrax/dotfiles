{
  config,
  user,
  ...
}:
{
  services.onepassword-secrets.secrets = {
    vector = {
      reference = "op://host-pumpkin/vector/envfile";
      owner = user.username;
    };
  };

  server.vector = {
    enable = true;
    environmentFiles = [ config.services.onepassword-secrets.secretPaths.vector ];
  };
}
