#!/usr/bin/env bash
# Update the pinned Wazuh MCP Server source, and gcf-python if upstream changed its pin.
#
# The script edits nix/pkgs/wazuh-mcp-server.nix, nix/pkgs/gcf-python.nix and the
# gitlink of the modules/wazuh-mcp-server submodule. It does not build or commit.
#
# Environment:
#   UPDATE_TRACK   "branch" (default) follows the newest commit on UPSTREAM_BRANCH.
#                  "release" follows the newest GitHub release.
#   UPSTREAM_BRANCH  Branch to follow when UPDATE_TRACK=branch. Default: main.
#   GITHUB_TOKEN   Optional. Raises the GitHub API rate limit.
#   GITHUB_OUTPUT  Set by GitHub Actions. The script writes its results there.
#
# Requires: bash, curl, jq, sed, git, nix (with flakes).
set -euo pipefail

owner=gensecaihq
repo=Wazuh-MCP-Server
track="${UPDATE_TRACK:-branch}"
branch="${UPSTREAM_BRANCH:-main}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pkg="$root/nix/pkgs/wazuh-mcp-server.nix"
gcf="$root/nix/pkgs/gcf-python.nix"
submodule=modules/wazuh-mcp-server

api() {
  local auth=()
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi
  curl -fsSL "${auth[@]}" -H "Accept: application/vnd.github+json" "https://api.github.com/$1"
}

raw() {
  curl -fsSL "https://raw.githubusercontent.com/$1/$2/$3"
}

prefetch() {
  nix flake prefetch --json "github:$1/$2" | jq -r .hash
}

output() {
  echo "$1=$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "$1=$2" >>"$GITHUB_OUTPUT"
  fi
}

# set_attr KEY FILE VALUE: replace the value of the first `KEY = "...";` line in FILE. Fail if there is none.
set_attr() {
  local key="$1" file="$2" value="$3"
  grep -qE "^\s*$key = \"[^\"]*\";" "$file" || {
    echo "update: no '$key = \"...\";' line in $file" >&2
    exit 1
  }
  sed -i -E "0,/^(\s*)$key = \"[^\"]*\";/s||\1$key = \"$value\";|" "$file"
}

get_attr() {
  sed -nE "s/^\s*$1 = \"([^\"]*)\";.*/\1/p" "$2" | head -n1
}

# 1. Find the target upstream commit.
case "$track" in
  branch)
    rev="$(api "repos/$owner/$repo/commits/$branch" | jq -r .sha)"
    ;;
  release)
    tag="$(api "repos/$owner/$repo/releases/latest" | jq -r .tag_name)"
    rev="$(api "repos/$owner/$repo/commits/$tag" | jq -r .sha)"
    ;;
  *)
    echo "update: UPDATE_TRACK must be 'branch' or 'release', not '$track'" >&2
    exit 1
    ;;
esac

current_rev="$(get_attr rev "$pkg")"
gcf_current="$(get_attr version "$gcf")"
changes=()

# 2. Update the server pin.
if [ "$rev" != "$current_rev" ]; then
  pyproject="$(raw "$owner/$repo" "$rev" pyproject.toml)"
  base="$(sed -nE 's/^version = "([^"]+)".*/\1/p' <<<"$pyproject" | head -n1)"
  date="$(api "repos/$owner/$repo/commits/$rev" | jq -r .commit.committer.date | cut -c1-10)"

  # A commit that a version tag points at gets the plain version.
  tagged="$(api "repos/$owner/$repo/tags?per_page=100" |
    jq -r --arg rev "$rev" --arg v "v$base" '.[] | select(.commit.sha == $rev and (.name == $v or .name == ($v | ltrimstr("v")))) | .name' |
    head -n1)"
  if [ -n "$tagged" ]; then
    version="$base"
  else
    version="$base-unstable-$date"
  fi

  hash="$(prefetch "$owner/$repo" "$rev")"
  set_attr version "$pkg" "$version"
  set_attr rev "$pkg" "$rev"
  set_attr hash "$pkg" "$hash"

  # Point the submodule at the same commit. The gitlink works without a checkout.
  git -C "$root" update-index --cacheinfo "160000,$rev,$submodule"
  if [ -e "$root/$submodule/.git" ]; then
    # The checkout is a convenience. The gitlink above is what a commit records.
    if git -C "$root/$submodule" fetch --quiet "https://github.com/$owner/$repo" "$rev" &&
      git -C "$root/$submodule" checkout --quiet "$rev"; then
      :
    else
      echo "update: could not check out $rev in $submodule. Run: git submodule update" >&2
    fi
  fi

  changes+=("wazuh-mcp-server: ${current_rev:0:7} -> ${rev:0:7} ($version)")
  output version "$version"
else
  pyproject="$(raw "$owner/$repo" "$rev" pyproject.toml)"
  output version "$(get_attr version "$pkg")"
fi
output rev "$rev"

# 3. Follow the exact gcf-python pin of upstream.
gcf_pin="$(grep -oE '"gcf-python==[^"]+"' <<<"$pyproject" | head -n1 | sed -E 's/"gcf-python==([^"]+)"/\1/')"
if [ -n "$gcf_pin" ] && [ "$gcf_pin" != "$gcf_current" ]; then
  gcf_hash="$(prefetch blackwell-systems/gcf-python "v$gcf_pin")"
  set_attr version "$gcf" "$gcf_pin"
  set_attr hash "$gcf" "$gcf_hash"
  changes+=("gcf-python: $gcf_current -> $gcf_pin")
fi

if [ "${#changes[@]}" -eq 0 ]; then
  echo "update: already at ${rev:0:7}, nothing to do"
  output updated false
  exit 0
fi

printf 'update: %s\n' "${changes[@]}"
output updated true
summary="$(printf '%s; ' "${changes[@]}")"
output summary "${summary%; }"
