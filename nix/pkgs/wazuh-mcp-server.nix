{
  lib,
  python3Packages,
  fetchFromGitHub,
  openssl,
  gcf-python,
}:

python3Packages.buildPythonApplication rec {
  pname = "wazuh-mcp-server";
  version = "5.0.0-unstable-2026-09-30";
  pyproject = true;

  # Keep rev equal to the modules/wazuh-mcp-server submodule commit.
  src = fetchFromGitHub {
    owner = "gensecaihq";
    repo = "Wazuh-MCP-Server";
    rev = "e751871c850ddccdf643785bc23cd38e859f1fba";
    hash = "sha256-JSkbtuvnpg9nkahoULQHWXs6vHEdkNavhVVu+uwNYmc=";
  };

  # Upstream starts the server with `python -m wazuh_mcp_server` and declares no
  # console script. Add one, so that the package gets a wrapped bin/ program.
  postPatch = ''
    cat >> pyproject.toml <<'EOF'

    [project.scripts]
    wazuh-mcp-server = "wazuh_mcp_server.__main__:main"
    EOF
  '';

  build-system = with python3Packages; [
    setuptools
    wheel
  ];

  dependencies =
    with python3Packages;
    [
      fastapi
      uvicorn
      httpx
      pydantic
      pyjwt
      cryptography
      python-multipart
      prometheus-client
      psutil
      tenacity
      python-dotenv
      # Optional extras. The upstream Docker image installs both, so do the same.
      redis
      gcf-python
    ]
    ++ uvicorn.optional-dependencies.standard
    ++ pyjwt.optional-dependencies.crypto;

  nativeCheckInputs = with python3Packages; [
    pytestCheckHook
    pytest-asyncio
    certifi
    openssl
  ];

  # Some tests import helpers from the repository root (tools/, evals/).
  preCheck = ''
    export PYTHONPATH="$PWD:$PYTHONPATH"
  '';

  # wazuh_mcp_server.server reads WAZUH_HOST, WAZUH_USER and WAZUH_PASS at import time,
  # so the import check covers only the top-level package. The tests cover the rest.
  pythonImportsCheck = [ "wazuh_mcp_server" ];

  meta = {
    description = "MCP remote server for Wazuh SIEM integration";
    homepage = "https://github.com/gensecaihq/Wazuh-MCP-Server";
    changelog = "https://github.com/gensecaihq/Wazuh-MCP-Server/blob/${src.rev}/CHANGELOG.md";
    license = lib.licenses.mit;
    mainProgram = "wazuh-mcp-server";
    platforms = lib.platforms.unix;
  };
}
