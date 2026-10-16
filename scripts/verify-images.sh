#!/usr/bin/env bash
#
# Release gate: every image the chart deploys must be pinned by digest
# (repository:tag@sha256:...) and carry a valid cosign signature from the
# ImageEngine image-signing key. Exits non-zero, naming each failing image, if
# any is not.
#
#   scripts/verify-images.sh [chart dir]   (default: charts/imageengine-kube)
#
# COSIGN_PUB: public key file (default: downloaded from
# https://kube.imageengine.io/cosign.pub). Needs helm and cosign, and read
# access to the image registry (docker login).
set -euo pipefail

chart="${1:-charts/imageengine-kube}"
for tool in helm cosign; do
  command -v "$tool" >/dev/null || { echo "error: $tool not found on PATH" >&2; exit 2; }
done

key="${COSIGN_PUB:-}"
if [ -z "$key" ]; then
  key=$(mktemp)
  trap 'rm -f "$key"' EXIT
  curl -fsSL https://kube.imageengine.io/cosign.pub -o "$key"
fi

# The default render deploys every component, so it lists every image.
images=$(helm template verify "$chart" | sed -n 's/^[[:space:]]*image:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' | sort -u)
[ -n "$images" ] || { echo "error: no images rendered from $chart" >&2; exit 2; }

failed=0
for img in $images; do
  if [[ "$img" != *@sha256:* ]]; then
    echo "NOT PINNED  $img (run scripts/pin-digests.sh)" >&2
    failed=1
    continue
  fi
  if cosign verify --key "$key" "$img" >/dev/null 2>&1; then
    echo "ok          $img"
  else
    echo "NOT SIGNED  $img" >&2
    failed=1
  fi
done
exit $failed
