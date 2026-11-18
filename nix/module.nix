{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.wazuh-mcp-server;
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  toEnvValue =
    v:
    if lib.isBool v then
      lib.boolToString v
    else if lib.isList v then
      lib.concatMapStringsSep "," toString v
    else
      toString v;

  environment = lib.mapAttrs (_: toEnvValue) (lib.filterAttrs (_: v: v != null) cfg.settings);

  # systemd credential names allow only some characters. Use the variable name in lowercase.
  credName = name: lib.toLower name;

  # Read each credential into its environment variable, then start the server.
  # The secret values never appear in the unit file, the Nix store, or the process argv.
  start = pkgs.writeShellScript "wazuh-mcp-server-start" ''
    set -euo pipefail
    ${lib.concatStrings (
      lib.mapAttrsToList (name: _: ''
        ${name}="$(< "$CREDENTIALS_DIRECTORY/${credName name}")"
        export ${name}
      '') cfg.secretFiles
    )}
    exec ${lib.getExe cfg.package}
  '';

  settingsType = types.submodule {
    freeformType = types.attrsOf (
      types.nullOr (
        types.oneOf [
          types.str
          types.int
          types.bool
          (types.listOf (types.either types.str types.int))
        ]
      )
    );

    options = {
      WAZUH_HOST = mkOption {
        type = types.str;
        example = "wazuh.example.com";
        description = "Host name or IP address of the Wazuh manager. The server always uses HTTPS for the manager API.";
      };

      WAZUH_PORT = mkOption {
        type = types.port;
        default = 55000;
        description = "TCP port of the Wazuh manager API.";
      };

      WAZUH_USER = mkOption {
        type = types.str;
        example = "wazuh-mcp";
        description = ''
          User name for the Wazuh manager API.
          Put the password in {option}`services.wazuh-mcp-server.secretFiles.WAZUH_PASS`.
        '';
      };

      MCP_HOST = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Address that the server listens on. The server speaks plain HTTP. Put a TLS reverse proxy in front of it for remote clients.";
      };

      MCP_PORT = mkOption {
        type = types.port;
        default = 3000;
        description = "TCP port that the server listens on.";
      };

      ENVIRONMENT = mkOption {
        type = types.enum [
          "production"
          "development"
        ];
        default = "production";
        description = ''
          Deployment mode. In production, the server requires `AUTH_SECRET_KEY` unless `AUTH_MODE` is `none`.
          Production also turns on `WAZUH_REQUIRE_ACTION_CONFIRMATION` unless you set it.
        '';
      };

      AUTH_MODE = mkOption {
        type = types.enum [
          "bearer"
          "oauth"
          "none"
        ];
        default = "bearer";
        description = "Client authentication mode.";
      };
    };
  };
in
{
  options.services.wazuh-mcp-server = {
    enable = mkEnableOption "the Wazuh MCP Server, an MCP remote server for the Wazuh SIEM";

    package = mkOption {
      type = types.package;
      default = pkgs.wazuh-mcp-server or (
        pkgs.callPackage ./pkgs/wazuh-mcp-server.nix {
          gcf-python = pkgs.python3Packages.callPackage ./pkgs/gcf-python.nix { };
        }
      );
      defaultText = lib.literalExpression "pkgs.wazuh-mcp-server";
      description = "The wazuh-mcp-server package to use. If `pkgs` has no such attribute, the module builds the package from this flake.";
    };

    settings = mkOption {
      type = settingsType;
      default = { };
      example = lib.literalExpression ''
        {
          WAZUH_HOST = "wazuh.example.com";
          WAZUH_USER = "wazuh-mcp";
          WAZUH_INDEXER_HOST = "wazuh.example.com";
          WAZUH_INDEXER_USER = "admin";
          WAZUH_CA_BUNDLE = "/etc/ssl/wazuh/root-ca.pem";
          ALLOWED_ORIGINS = [ "https://claude.ai" ];
          WAZUH_TOOLSETS = [ "alerts" "agents" "vulnerabilities" "analysis" "compliance" "system" ];
        }
      '';
      description = ''
        Environment variables for the server. The upstream file `.env.example` and
        `docs/configuration.md` list all the variables.
        Booleans become `true` or `false`. Lists become comma-separated values. A `null` value removes the variable.
        Do not put secrets here. The values go into the world-readable Nix store.
        Use {option}`services.wazuh-mcp-server.secretFiles` for secrets.
      '';
    };

    secretFiles = mkOption {
      type = types.attrsOf types.path;
      default = { };
      example = {
        WAZUH_PASS = "/run/secrets/wazuh-mcp/wazuh-pass";
        WAZUH_INDEXER_PASS = "/run/secrets/wazuh-mcp/indexer-pass";
        AUTH_SECRET_KEY = "/run/secrets/wazuh-mcp/auth-secret-key";
        MCP_API_KEY = "/run/secrets/wazuh-mcp/api-key";
      };
      description = ''
        Environment variables to read from files at service start.
        Each attribute name is a variable name. Each value is the path of a file that holds the value.
        systemd loads the files with `LoadCredential=`, so the files can be readable by root only.
        Typical variables are `WAZUH_PASS`, `WAZUH_INDEXER_PASS`, `AUTH_SECRET_KEY`, `MCP_API_KEY`,
        `API_KEYS`, `OAUTH_IDP_CLIENT_SECRET`, `REDIS_URL` and `YDC_API_KEY`.
      '';
    };

    environmentFiles = mkOption {
      type = types.listOf types.path;
      default = [ ];
      description = ''
        Files in systemd `EnvironmentFile=` format, for example an `.env` file.
        Values in these files override {option}`services.wazuh-mcp-server.settings`.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open {option}`services.wazuh-mcp-server.settings.MCP_PORT` in the firewall.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.secretFiles ? WAZUH_PASS || cfg.environmentFiles != [ ];
        message = "services.wazuh-mcp-server: set secretFiles.WAZUH_PASS (or supply WAZUH_PASS in environmentFiles).";
      }
      {
        assertion =
          cfg.settings.ENVIRONMENT != "production"
          || cfg.settings.AUTH_MODE == "none"
          || cfg.secretFiles ? AUTH_SECRET_KEY
          || cfg.environmentFiles != [ ];
        message = "services.wazuh-mcp-server: production mode requires secretFiles.AUTH_SECRET_KEY (or AUTH_SECRET_KEY in environmentFiles), unless settings.AUTH_MODE is \"none\".";
      }
      {
        assertion = lib.all (n: builtins.match "[A-Z_][A-Z0-9_]*" n != null) (lib.attrNames cfg.secretFiles);
        message = "services.wazuh-mcp-server: secretFiles names must be environment variable names (A-Z, 0-9 and _).";
      }
    ];

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.settings.MCP_PORT ];

    systemd.services.wazuh-mcp-server = {
      description = "Wazuh MCP Server";
      documentation = [ "https://github.com/gensecaihq/Wazuh-MCP-Server" ];
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      environment = environment // {
        PYTHONUNBUFFERED = "1";
      };

      serviceConfig = {
        ExecStart = start;
        EnvironmentFile = cfg.environmentFiles;
        LoadCredential = lib.mapAttrsToList (name: path: "${credName name}:${path}") cfg.secretFiles;

        DynamicUser = true;
        StateDirectory = "wazuh-mcp-server";
        # The server reads ./config/wazuh.env and ./config/clusters.json relative to this directory.
        WorkingDirectory = "/var/lib/wazuh-mcp-server";

        Restart = "on-failure";
        RestartSec = 5;
        # Upstream bounds the graceful shutdown to 20 seconds.
        TimeoutStopSec = 30;

        # Hardening
        CapabilityBoundingSet = "";
        DevicePolicy = "closed";
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        PrivateUsers = true;
        ProcSubset = "pid";
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        RemoveIPC = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~@resources"
        ];
        UMask = "0077";
      };
    };
  };
}
