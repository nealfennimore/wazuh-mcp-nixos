# Wazuh MCP Server for NixOS

This flake packages [Wazuh MCP Server](https://github.com/gensecaihq/Wazuh-MCP-Server) for Nix and NixOS.
The server is a Model Context Protocol (MCP) remote server for the Wazuh SIEM. MCP clients, for example Claude, use it to query Wazuh alerts, agents, and vulnerabilities.

## Contents

| Output | Description |
| --- | --- |
| `packages.x86_64-linux.wazuh-mcp-server` (also `default`) | The server, with the program `wazuh-mcp-server`. |
| `packages.x86_64-linux.gcf-python` | `gcf-python` 2.7.1, the optional GCF response encoder. nixpkgs does not have it. |
| `overlays.default` | Adds `pkgs.wazuh-mcp-server` and `python3Packages.gcf-python`. |
| `nixosModules.default` | The `services.wazuh-mcp-server` module. |
| `checks.x86_64-linux.nixos` | A NixOS VM test with a mock Wazuh manager. |

The package build runs the 641 upstream tests. The upstream source is pinned to the commit of the `modules/wazuh-mcp-server` submodule.

## Use the module

1. Add the flake to the inputs of your NixOS flake:

   ```nix
   inputs.wazuh-mcp.url = "git+file:///home/neal/Documents/wazuh-mcp";
   ```

2. Import the module and configure the service:

   ```nix
   {
     imports = [ inputs.wazuh-mcp.nixosModules.default ];

     services.wazuh-mcp-server = {
       enable = true;
       settings = {
         WAZUH_HOST = "wazuh.example.com";
         WAZUH_USER = "wazuh-mcp";
         WAZUH_CA_BUNDLE = "/etc/ssl/wazuh/root-ca.pem";
         WAZUH_INDEXER_HOST = "wazuh.example.com";
         WAZUH_INDEXER_USER = "wazuh-mcp";
         ALLOWED_ORIGINS = [ "https://claude.ai" ];
       };
       secretFiles = {
         WAZUH_PASS = "/run/secrets/wazuh-mcp/wazuh-pass";
         WAZUH_INDEXER_PASS = "/run/secrets/wazuh-mcp/indexer-pass";
         AUTH_SECRET_KEY = "/run/secrets/wazuh-mcp/auth-secret-key";
         MCP_API_KEY = "/run/secrets/wazuh-mcp/api-key";
       };
     };
   }
   ```

3. Make the secret files. Each file holds only the value:

   ```sh
   openssl rand -hex 32 > auth-secret-key
   printf 'wazuh_%s' "$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')" > api-key
   ```

### Module behavior

- `settings` holds environment variables. The upstream `.env.example` lists all of them. Booleans become `true` or `false`. Lists become comma-separated values.
- `secretFiles` maps a variable name to a file. systemd loads each file with `LoadCredential=`. The files can be readable by root only. The values do not go into the Nix store, the unit file, or the process arguments.
- `environmentFiles` accepts files in `.env` format, as an alternative to `secretFiles`.
- `ENVIRONMENT` defaults to `production`. In production mode, the server requires `AUTH_SECRET_KEY` unless `AUTH_MODE` is `none`. Production mode also requires `confirm=true` on write tools.
- The server listens on `127.0.0.1:3000` by default. It speaks plain HTTP. Put a TLS reverse proxy in front of it for remote clients, and set `TRUSTED_PROXIES` to the proxy address.
- The service runs as a `DynamicUser` with a strict systemd sandbox. `systemd-analyze security` gives it an exposure level of 1.1.

### Manager TLS

The server verifies the manager certificate by default. The stock Wazuh API certificate has no subjectAltName, so verification fails. Do one of these:

- Reissue the manager certificate with a subjectAltName for `WAZUH_HOST`, and set `WAZUH_CA_BUNDLE` to its CA.
- Set `WAZUH_ALLOW_SELF_SIGNED = true`. The server then does not verify the certificate.

The package uses Python 3.14. Python 3.13 and later verify certificates in X.509 strict mode. In strict mode, the CA certificate must have `basicConstraints=critical,CA:TRUE`, and the server certificate must have an `authorityKeyIdentifier`. Certificates from `wazuh-certs-tool` meet these rules. Some hand-made certificates do not.

## Connect a client

Exchange the API key for a bearer token, then give the token to the MCP client:

```sh
curl -s -H 'Content-Type: application/json' \
  -d "{\"api_key\": \"$(cat api-key)\"}" http://127.0.0.1:3000/auth/token
```

The MCP endpoint is `http://<host>:3000/mcp`. The health endpoint is `/health`, and the readiness endpoint is `/ready`.

## Build and test

```sh
nix build .#wazuh-mcp-server
nix build .#checks.x86_64-linux.nixos -L
```

The VM test starts three machines:

1. `wazuh` runs a mock Wazuh manager API over HTTPS, with a certificate from a private CA.
2. `mcp` runs the module with secrets in root-only files.
3. `client` calls the server over the network.

The test checks the health, readiness, and metrics endpoints, the token exchange, and the refusal of unauthenticated requests. It also checks an MCP session (`initialize`, `tools/list`, `tools/call get_wazuh_agents`), a restart, and the systemd hardening score.

## Update the upstream version

1. Update the submodule: `git -C modules/wazuh-mcp-server pull`.
2. Set `rev` in `nix/pkgs/wazuh-mcp-server.nix` to the new submodule commit, and set `version`.
3. Get the new hash: `nix flake prefetch --json github:gensecaihq/Wazuh-MCP-Server/<rev>`. Put the `hash` value in the file.
4. Build the package and run the VM test.
