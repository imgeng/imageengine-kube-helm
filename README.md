# imageengine-kube-helm

Helm chart repository for [ImageEngine](https://imageengine.io) Kube — the
self-hosted, Kubernetes-native image optimization and delivery platform from
[ScientiaMobile](https://www.scientiamobile.com).

The chart is published to **`https://kube.imageengine.io`** via GitHub
Pages, and a copy of the index is also reachable at
`https://imgeng.github.io/imageengine-kube-helm/`.

## Install

```bash
helm repo add imageengine https://kube.imageengine.io
helm repo update

# Everything lives in its own namespace. Create it up front so the secrets
# below land in the same place the chart installs into.
kubectl create namespace imageengine

# Create the two required secrets — the chart does NOT create these for you,
# and `helm install` will fail without them.
kubectl create secret generic ie-kube-api-key -n imageengine \
  --from-literal=KEY=<your-api-key>

kubectl create secret docker-registry ie-kube-image-pull -n imageengine \
  --docker-server=https://docker.scientiamobile.com/v2/ \
  --docker-username=<your-email> \
  --docker-password=<your-api-key> \
  --docker-email=<your-email>

helm install imageengine-kube imageengine/imageengine-kube \
  --namespace imageengine \
  -f imageengine-values.yaml
```

> An active ImageEngine Kube trial or subscription is required — the chart
> pulls images from `docker.scientiamobile.com` using your API key and
> authenticates to the ImageEngine control plane with the same key. Sign up at
> [imageengine.io](https://imageengine.io). See the chart's
> [Quick start](charts/imageengine-kube/README.md#quick-start) for full details
> on the required secrets and a minimal values file.

For the full quick-start, provider presets, customization options, and
troubleshooting, see [`charts/imageengine-kube/README.md`](charts/imageengine-kube/README.md)
and the docs under [`charts/imageengine-kube/docs/`](charts/imageengine-kube/docs/).

## Verifying chart signatures

Every chart `.tgz` is GPG-signed with key `releases@imageengine.io`
(fingerprint `C3A5 5111 ED91 FEDE 4A82 A4B4 4632 6606 0957 C4B3`). The public
key is published at
[`https://kube.imageengine.io/pubkey.asc`](https://kube.imageengine.io/pubkey.asc),
and a `.prov` provenance file is published alongside every release.

See the chart's [Verifying the chart signature](charts/imageengine-kube/README.md#verifying-the-chart-signature-optional)
section for a step-by-step.

## Verifying image signatures

Beyond the chart, every **container image** it deploys is cosign-signed and ships an SBOM +
SLSA build provenance. The cosign public key is published at
[`https://kube.imageengine.io/cosign.pub`](https://kube.imageengine.io/cosign.pub) — separate
from the GPG chart key above.

```bash
curl -fsSLO https://kube.imageengine.io/cosign.pub
cosign verify --key cosign.pub \
  docker.scientiamobile.com/iekube/imageengine-backend.server:<tag>
```

See [`charts/imageengine-kube/docs/SECURITY.md`](charts/imageengine-kube/docs/SECURITY.md) for
verifying every image, inspecting the SBOM/provenance, the vulnerability-scan posture, and
optional in-cluster signature enforcement (Kyverno / sigstore policy-controller).

## Releases and source

- **Releases:** see [Releases](../../releases) — each tagged release has a
  signed `.tgz` package as an asset, mirrored to the `gh-pages` branch.
- **Source of truth:** this public repository is the canonical source for the
  chart. Issues, feature requests, and pull requests against the chart are
  welcome here.

## Repository layout

```
charts/imageengine-kube/   # the chart itself: templates, values, docs
.github/workflows/         # chart-releaser-action release pipeline
```

The `gh-pages` branch hosts the served Helm repo: `index.yaml`, signed `.tgz`
packages and `.prov` files, the public key, and the landing page.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
