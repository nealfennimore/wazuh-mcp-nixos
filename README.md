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
| `checks.x86_64-linux.lint` | `actionlint` and `shellcheck` for the workflows and scripts. |

The package build runs the 641 upstream tests. The upstream source is pinned to the commit of the `modules/wazuh-mcp-server` submodule.

## Use the module

1. Add the flake to the inputs of your NixOS flake:

   ```nix
   inputs.wazuh-mcp = {
     # After you push the repository, use "github:<owner>/<repo>" instead.
     url = "git+file:///home/neal/Documents/wazuh-mcp";
     inputs.nixpkgs.follows = "nixpkgs";
   };
   ```

   The module builds the package with the `pkgs` of your system. The `follows` line makes the flake checks use the same nixpkgs.

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

GitHub Actions does the update automatically. See [Automatic updates](#automatic-updates).

To update by hand:

1. Run `nix/update.sh`. The script finds the newest upstream commit, and sets `version`, `rev` and `hash` in `nix/pkgs/wazuh-mcp-server.nix`. It also moves the submodule to the same commit. If upstream changed its `gcf-python` pin, the script updates `nix/pkgs/gcf-python.nix` too.
2. Build the package and run the VM test.
3. Commit the changes.

To follow GitHub releases instead of the newest commit on `main`, run `UPDATE_TRACK=release nix/update.sh`.

## Continuous integration

The flake has one input, `nixpkgs` (`nixos-unstable`), so CI builds the same derivations as a local build.

### Workflows

| Workflow | When | What it does |
| --- | --- | --- |
| `.github/workflows/ci.yml` | Push to `main`, pull requests, by hand | Lints the workflows and the update script, builds both packages with their tests, and runs the VM test. |
| `.github/workflows/update.yml`, job `upstream` | Every day at 06:17 UTC, by hand | Runs `nix/update.sh`. If there is a new upstream version, it builds, runs the VM test, and then opens a pull request on the branch `update/wazuh-mcp-server`. |
| `.github/workflows/update.yml`, job `nixpkgs` | Every Monday at 05:43 UTC, by hand | Runs `nix flake update nixpkgs`. If the revision changed, it lints, builds, runs the VM test, and then opens a pull request on the branch `update/nixpkgs`. |
| `.github/dependabot.yml` | Every week | Opens pull requests for new versions of the actions. |

To start an update by hand, run the `Update` workflow and select `upstream` or `nixpkgs`.

### Automatic updates

The update jobs open a pull request only after the build and the VM test pass. A pull request that `GITHUB_TOKEN` opens does not start `ci.yml`, so the update jobs run the same checks themselves. Each job uses its own branch. A new run replaces the open pull request of the same job. If the build or the test fails, the run fails and GitHub sends a notification.

To set up the repository on GitHub:

1. Push this repository to GitHub.
2. Go to **Settings > Actions > General > Workflow permissions**.
3. Select **Allow GitHub Actions to create and approve pull requests**.
4. Optional: to follow releases instead of `main`, add the repository variable `UPDATE_TRACK` with the value `release`.

The VM test needs KVM. The local action `.github/actions/setup-nix` gives the runner user access to `/dev/kvm`. GitHub-hosted Linux runners support KVM.
