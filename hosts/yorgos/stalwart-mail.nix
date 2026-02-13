# Heavily inspired by:
# https://github.com/oddlama/nix-config/blob/aa47d90/hosts/envoy/stalwart-mail.nix
# https://wiki.nixos.org/wiki/Stalwart
{
  config,
  user,
  pkgs,
  ...
}:
let
  primaryDomain = config.networking.domain;
  stalwartDomain = "mail.${primaryDomain}";
in
{
  services.onepassword-secrets.secrets = {
    stalwartAdminPw = {
      reference = "op://host-yorgos/stalwart/admin-pw";
      owner = "stalwart-mail";
      services = [ "stalwart-mail" ];
    };
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = user.email;
    certs."mail.wrx.sh" = {
      group = "stalwart-mail";
      # If Caddy is on port 80, use webroot
      webroot = "/var/lib/acme/acme-challenge";
      reloadServices = [
        "stalwart-mail"
        "caddy"
      ];
    };
  };

  users.users.caddy.extraGroups = [ "stalwart-mail" ];

  networking.firewall.allowedTCPPorts = [
    25 # smtp
    465 # submission tls
    # 587 # submission starttls
    993 # imap tls
    # 143 # imap starttls
    4190 # manage sieve
  ];

  services.stalwart-mail = {
    enable = true;
    settings = {
      config.local-keys = [
        # defaults
        "store.*"
        "directory.*"
        "tracer.*"
        "server.*"
        "!server.blocked-ip.*"
        "!server.allowed-ip.*"
        "authentication.fallback-admin.*"
        "cluster.*"
        "storage.data"
        "storage.blob"
        "storage.lookup"
        "storage.fts"
        "storage.directory"
        # new
        "spam-filter.resource"
        "web-admin.resource"
        "web-admin.path"
        "config.local-keys.*"
        "lookup.default.hostname"
        "certificate.*"
        "imap.*"
        "session.*"
        "resolver.*"
      ];

      authentication.fallback-admin = {
        user = "admin";
        secret = "%{file:${config.services.onepassword-secrets.secretPaths.stalwartAdminPw}}%";
      };

      tracer.stdout = {
        # Do not use the built-in journal tracer, as it shows much less auxiliary
        # information for the same loglevel
        type = "stdout";
        level = "info";
        ansi = false; # no colour markers to journald
        enable = true;
      };

      store.db = {
        type = "postgresql";
        host = "localhost";
        port = 5432;
        database = "stalwart-mail";
        user = "stalwart-mail";
        password = "%{file:${config.services.onepassword-secrets.secretPaths.stalwartAdminPw}}%";
        query = {
          name = "SELECT name, type, secret, description, quota FROM accounts WHERE name = $1 AND active = true";
          members = "SELECT member_of FROM group_members WHERE name = $1";
          recipients = "SELECT name FROM emails WHERE address = $1";
          emails = "SELECT address FROM emails WHERE name = $1 AND type != 'list' ORDER BY type DESC, address ASC";
          secrets = "SELECT secret FROM accounts WHERE name = $1 AND active = true";
        };
      };

      directory.db = {
        type = "sql";
        store = "db";
        columns = {
          name = "name";
          description = "description";
          secret = "secret";
          email = "email";
          quota = "quota";
          class = "type";
        };
      };

      storage = {
        data = "db";
        fts = "db";
        lookup = "db";
        blob = "db";
        directory = "db";
      };

      resolver = {
        type = "system";
        public-suffix = [
          "file://${pkgs.publicsuffix-list}/share/publicsuffix/public_suffix_list.dat"
        ];
      };

      spam-filter.resource = "file://${config.services.stalwart-mail.package}/etc/stalwart/spamfilter.toml";
      webadmin.resource = "file://${config.services.stalwart-mail.package.webadmin}/webadmin.zip";
      webadmin.path = "/var/cache/stalwart-mail";

      calendar.default.display-name = "Personal Calendar";
      contacts.default.display-name = "Personal Contacts";

      certificate.default = {
        cert = "%{file:/var/lib/acme/mail.wrx.sh/fullchain.pem}%";
        private-key = "%{file:/var/lib/acme/mail.wrx.sh/key.pem}%";
        default = true;
      };

      server = {
        hostname = stalwartDomain;
        tls = {
          certificate = "default";
          ignore-client-order = true;
        };
        socket = {
          nodelay = true;
          reuse-addr = true;
        };
        listener = {
          smtp = {
            protocol = "smtp";
            bind = "[::]:25";
          };
          submissions = {
            protocol = "smtp";
            bind = "[::]:465";
            tls.implicit = true;
          };
          imaps = {
            protocol = "imap";
            bind = "[::]:993";
            tls.implicit = true;
          };
          http = {
            # jmap, web interface
            protocol = "http";
            bind = "[::]:8081";
            url = "https://${stalwartDomain}";
            use-x-forwarded = true;
          };
          sieve = {
            protocol = "managesieve";
            bind = "[::]:4190";
            tls.implicit = true;
          };
        };
      };

      imap = {
        request.max-size = 52428800;
        auth = {
          max-failures = 3;
          allow-plain-text = false;
        };
        timeout = {
          authentication = "30m";
          anonymous = "1m";
          idle = "30m";
        };
        rate-limit = {
          requests = "20000/1m";
          concurrent = 32;
        };
      };
    };
  };
}
