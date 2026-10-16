#!/usr/bin/env bash
#
# CI release gate (release.yml, verify-images.yml): if the chart's version has
# not been released yet, log in to the image registry and run
# verify-images.sh, which fails unless every image is pinned by digest and
# signed. A version that is already released is skipped: chart-releaser
# would publish nothing for it.
#
# Env: REGISTRY_USER, REGISTRY_TOKEN (read access to the image registry).
set -euo pipefail

chart=charts/imageengine-kube
name=$(sed -n 's/^name: *//p' "$chart/Chart.yaml")
version=$(sed -n 's/^version: *//p' "$chart/Chart.yaml")

git fetch -q --tags origin || true
if git rev-parse -q --verify "refs/tags/$name-$version" >/dev/null; then
  echo "$name $version is already released; nothing to verify."
  exit 0
fi

if [ -z "${REGISTRY_USER:-}" ] || [ -z "${REGISTRY_TOKEN:-}" ]; then
  echo "error: the IMAGE_REGISTRY_USER and IMAGE_REGISTRY_TOKEN secrets are needed to verify the images of $name $version" >&2
  exit 1
fi
printf '%s' "$REGISTRY_TOKEN" | docker login docker.scientiamobile.com -u "$REGISTRY_USER" --password-stdin >/dev/null

echo "Verifying the images of $name $version:"
scripts/verify-images.sh "$chart"
