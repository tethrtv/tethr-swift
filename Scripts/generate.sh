#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift run --package-path Tools swift-openapi-generator generate \
  --config Sources/Tethr/Generated/openapi-generator-config.yaml \
  --output-directory Sources/Tethr/Generated \
  openapi.yaml
