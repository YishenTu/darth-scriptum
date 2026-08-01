#!/bin/zsh

set -euo pipefail

script_path="${0:A}"
repository_root="${script_path:h:h}"

cd "$repository_root"

xcrun swift-format lint \
  --configuration .swift-format \
  --strict \
  --recursive \
  Sources \
  Tests
