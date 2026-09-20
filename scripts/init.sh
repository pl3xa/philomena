#!/usr/bin/env bash
# Script to initialize the repo for development.

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

function fetch {
  local url="$1"
  local github_token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  local headers=()

  if [[ "$url" == https://api.github.com/* && -n "$github_token" ]]; then
    headers+=(--header "Authorization: Bearer $github_token")
  fi

  # Do not use step here: it prints arguments, including authorization headers.
  info "Fetching $url"
  curl --fail --silent --show-error --location --retry 5 --retry-all-errors "${headers[@]}" "$url"
}

function fetch_github_artifact_url {
  local owner_and_repo="$1"
  local artifact_pattern="$2"

  fetch "https://api.github.com/repos/$owner_and_repo/releases/latest" \
    | grep browser_download_url \
    | grep "$artifact_pattern" \
    | cut --delimiter '"' --fields 4
}

# Install `typos` CLI
typos_url=$(fetch_github_artifact_url crate-ci/typos x86_64-unknown-linux-musl)
fetch "$typos_url" | step sudo tar -xzC /usr/local/bin ./typos

# Install prettier (see top-level package.json)
step npm ci --ignore-scripts

# Install the pre-commit hook. It's a symlink, to make sure it stays always up-to-date.
step ln -sf ../../.githooks/pre-commit .git/hooks/pre-commit
