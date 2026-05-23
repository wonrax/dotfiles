{ inputs, user, ... }:
{
  imports = [ inputs.xremap-flake.nixosModules.default ];

  services.xremap = {
    enable = true;
    serviceMode = "user";
    userName = user.username;
    config.modmap = [
      {
        name = "Global";
        remap.CapsLock = "Esc";
      }
    ];
  };
}
