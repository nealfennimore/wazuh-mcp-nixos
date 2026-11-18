# Stand-in for the `nixos` input on CI runners.
#
# The real input is git+file:///home/neal/Documents/nixos, which exists only on
# Neal's machine. CI replaces it with this flake (see ci/flake-args). The packages,
# the module and the checks do not use it. Only the devShell uses its claude sandbox.
{
  outputs = _: {
    packages.x86_64-linux.claude = throw "The claude sandbox comes from the host nixos repo. It is not available on CI.";
  };
}
