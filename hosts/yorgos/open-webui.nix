{
  lib,
  ...
}:

{
  # make sure mounted directories are created first
  systemd.tmpfiles.rules = [
    "d /etc/open-webui 0774 root root -"
    "d /var/open-webui/data 0774 root root -"
  ];

  # # Containers
  virtualisation.oci-containers.containers."open-webui" = {
    image = "ghcr.io/open-webui/open-webui:main";
    environmentFiles = [
      "/etc/open-webui/.env"
    ];
    environment = {
      ENV = "prod";
      WEBUI_AUTH = "true";
      ENABLE_SIGNUP = "true";
      ENABLE_LOGIN_FORM = "true";
      DEFAULT_USER_ROLE = "pending";
      ENABLE_MESSAGE_RATING = "false";
      DATABASE_POOL_SIZE = "10";
      ENABLE_OLLAMA_API = "false";
      # The two options below helps significantly reducing RAM usage (from
      # 600MB to 240MB)
      # https://docs.openwebui.com/tutorials/tips/reduce-ram-usage
      AUDIO_STT_ENGINE = "openai";
      RAG_EMBEDDING_ENGINE = "ollama";
    };
    ports = [
      "8080:8080"
    ];
    volumes = [
      "/var/open-webui/data:/app/backend/data:rw"
    ];
    log-driver = "journald";
    labels = {
      "io.containers.autoupdate" = "registry";
    };
  };

  systemd.services."podman-open-webui" = {
    serviceConfig = {
      Restart = lib.mkOverride 90 "always";
    };
    after = [
      "postgresql.service"
    ];
    requires = [
      "postgresql.service"
    ];
  };
}
