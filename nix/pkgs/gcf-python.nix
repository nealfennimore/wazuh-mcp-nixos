{
  lib,
  buildPythonPackage,
  fetchFromGitHub,
  hatchling,
  pytestCheckHook,
}:

buildPythonPackage rec {
  pname = "gcf-python";
  version = "2.7.1";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "blackwell-systems";
    repo = "gcf-python";
    tag = "v${version}";
    hash = "sha256-lXvejwofMtrJqLnGElhO3S3WTG5zPQ9k/wGb/1K6Pe8=";
  };

  build-system = [ hatchling ];

  nativeCheckInputs = [ pytestCheckHook ];

  # The fastmcp integration needs the optional fastmcp extra, which is not packaged here.
  disabledTestPaths = [ "tests/test_fastmcp.py" ];

  pythonImportsCheck = [ "gcf" ];

  meta = {
    description = "Python implementation of GCF (Graph Compact Format), a token-efficient wire format";
    homepage = "https://github.com/blackwell-systems/gcf-python";
    license = lib.licenses.mit;
    mainProgram = "gcf";
  };
}
