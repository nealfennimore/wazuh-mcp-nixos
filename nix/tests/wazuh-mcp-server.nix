{ self }:

{ pkgs, lib, ... }:

let
  apiKey = "wazuh_" + lib.concatStrings (lib.replicate 43 "x");
  authSecretKey = "3f1c9a7e5b2d4f6081a3c5e7f9b1d3e5a7c9e1f3b5d7f9a1c3e5b7d9f1a3c5e7";
  managerPassword = "mock-manager-password";

  # A private CA and a manager certificate with subjectAltName=DNS:wazuh, so that
  # the server verifies the manager certificate instead of skipping verification.
  # Python 3.13 and later verify in X.509 strict mode. Strict mode requires the
  # CA extensions and the authorityKeyIdentifier on the leaf certificate.
  certs = pkgs.runCommand "wazuh-mock-certs" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p $out
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=Mock Wazuh CA" \
      -addext "basicConstraints=critical,CA:TRUE" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -addext "subjectKeyIdentifier=hash" \
      -keyout $out/ca.key -out $out/ca.pem
    openssl req -newkey rsa:2048 -nodes -subj "/CN=wazuh" \
      -keyout $out/manager.key -out manager.csr
    cat > ext.cnf <<'EOF'
    basicConstraints=critical,CA:FALSE
    keyUsage=critical,digitalSignature,keyEncipherment
    extendedKeyUsage=serverAuth
    subjectAltName=DNS:wazuh
    subjectKeyIdentifier=hash
    authorityKeyIdentifier=keyid,issuer
    EOF
    openssl x509 -req -in manager.csr -CA $out/ca.pem -CAkey $out/ca.key -CAcreateserial \
      -days 3650 -extfile ext.cnf -out $out/manager.pem
  '';

  secret = text: {
    inherit text;
    mode = "0400";
  };
in
{
  name = "wazuh-mcp-server";

  nodes = {
    wazuh =
      { ... }:
      {
        networking.firewall.allowedTCPPorts = [ 55000 ];
        systemd.services.mock-wazuh-manager = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${pkgs.python3.interpreter} ${./mock-wazuh-manager.py} ${certs}/manager.pem ${certs}/manager.key 55000";
        };
      };

    mcp =
      { ... }:
      {
        imports = [ self.nixosModules.default ];

        # Root-only files. The service reads them through LoadCredential.
        environment.etc."wazuh-mcp/wazuh-pass" = secret managerPassword;
        environment.etc."wazuh-mcp/auth-secret-key" = secret authSecretKey;
        environment.etc."wazuh-mcp/api-key" = secret apiKey;

        services.wazuh-mcp-server = {
          enable = true;
          openFirewall = true;
          settings = {
            WAZUH_HOST = "wazuh";
            WAZUH_USER = "wazuh-mcp";
            WAZUH_CA_BUNDLE = "${certs}/ca.pem";
            MCP_HOST = "0.0.0.0";
            ALLOWED_ORIGINS = [ "https://claude.ai" ];
            MCP_API_KEY_SCOPES = "wazuh:read";
            WAZUH_TOOLSETS = [
              "agents"
              "system"
            ];
          };
          secretFiles = {
            WAZUH_PASS = "/etc/wazuh-mcp/wazuh-pass";
            AUTH_SECRET_KEY = "/etc/wazuh-mcp/auth-secret-key";
            MCP_API_KEY = "/etc/wazuh-mcp/api-key";
          };
        };
      };

    client =
      { ... }:
      {
        environment.systemPackages = [ pkgs.curl ];
      };
  };

  testScript = ''
    import base64
    import datetime
    import json

    API_KEY = "${apiKey}"
    WRONG_KEY = "wazuh_" + "y" * 43
    BASE = "http://mcp:3000"


    def curl(args):
        return client.succeed(f"curl --fail-with-body -sS {args}")


    def mcp_call(token, payload, session=None, version="2025-11-25"):
        headers = (
            f"-H 'Authorization: Bearer {token}' "
            "-H 'Content-Type: application/json' "
            "-H 'Accept: application/json, text/event-stream' "
            f"-H 'MCP-Protocol-Version: {version}' "
        )
        if session:
            headers += f"-H 'MCP-Session-Id: {session}' "
        b64 = base64.b64encode(json.dumps(payload).encode()).decode()
        client.succeed(f"echo {b64} | base64 -d > /tmp/body")
        out = curl(f"-D /tmp/headers {headers} --data-binary @/tmp/body {BASE}/mcp")
        hdrs = client.succeed("cat /tmp/headers")
        sid = None
        for line in hdrs.splitlines():
            if line.lower().startswith("mcp-session-id:"):
                sid = line.split(":", 1)[1].strip()
        if out.lstrip().startswith("event:") or out.lstrip().startswith("data:"):
            data = [l[5:].strip() for l in out.splitlines() if l.startswith("data:")]
            out = data[-1]
        return (json.loads(out) if out.strip() else None), sid


    start_all()
    wazuh.wait_for_unit("mock-wazuh-manager.service")
    wazuh.wait_for_open_port(55000)

    mcp.wait_for_unit("wazuh-mcp-server.service")
    mcp.wait_for_open_port(3000)

    with subtest("the service runs as a dynamic user and cannot read the secret files"):
        mcp.succeed("systemctl show -p DynamicUser --value wazuh-mcp-server | grep -qx yes")
        mcp.fail("systemd-run --pipe --wait -p DynamicUser=yes cat /etc/wazuh-mcp/wazuh-pass")
        # The secret values must not be in the unit environment.
        env = mcp.succeed("systemctl show -p Environment --value wazuh-mcp-server")
        assert "${managerPassword}" not in env, env
        assert API_KEY not in env, env

    with subtest("health endpoint"):
        health = json.loads(curl(f"{BASE}/health"))
        assert health["status"] == "healthy", health
        assert health["version"] == "5.0.0", health

    with subtest("readiness: the server reaches the manager over verified TLS"):
        client.wait_until_succeeds(f"curl --fail -sS {BASE}/ready", timeout=datetime.timedelta(seconds=60))
        ready = json.loads(curl(f"{BASE}/ready"))
        print(json.dumps(ready, indent=2))

    with subtest("metrics endpoint"):
        curl(f"{BASE}/metrics | grep -q '^# HELP'")

    with subtest("unauthenticated MCP requests are refused"):
        client.fail(f"curl --fail -sS -H 'Content-Type: application/json' -d '{{}}' {BASE}/mcp")

    with subtest("exchange the API key for a bearer token"):
        token = json.loads(curl(f"-H 'Content-Type: application/json' -d '{{\"api_key\": \"{API_KEY}\"}}' {BASE}/auth/token"))["access_token"]
        client.fail(f"curl --fail -sS -H 'Content-Type: application/json' -d '{{\"api_key\": \"{WRONG_KEY}\"}}' {BASE}/auth/token")

    with subtest("MCP initialize, tools/list and tools/call against the mock manager"):
        init, sid = mcp_call(token, {
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "nixos-test", "version": "1"}},
        })
        assert "result" in init, init
        assert sid, "no MCP-Session-Id header"
        mcp_call(token, {"jsonrpc": "2.0", "method": "notifications/initialized"}, session=sid)

        tools, _ = mcp_call(token, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, session=sid)
        names = {t["name"] for t in tools["result"]["tools"]}
        print(sorted(names))
        assert "get_wazuh_agents" in names, names
        # WAZUH_TOOLSETS limits the tools. The alerts toolset is not enabled.
        assert "get_wazuh_alerts" not in names, names

        res, _ = mcp_call(token, {
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": {"name": "get_wazuh_agents", "arguments": {}},
        }, session=sid)
        print(json.dumps(res, indent=2))
        assert not res["result"].get("isError"), res
        text = "".join(c.get("text", "") for c in res["result"]["content"])
        assert "web01" in text, text

    with subtest("the service restarts cleanly"):
        mcp.succeed("systemctl restart wazuh-mcp-server.service")
        mcp.wait_for_unit("wazuh-mcp-server.service")
        mcp.wait_for_open_port(3000)
        curl(f"{BASE}/health")

    with subtest("systemd hardening score"):
        print(mcp.succeed("systemd-analyze security wazuh-mcp-server.service | tail -1"))
  '';
}
