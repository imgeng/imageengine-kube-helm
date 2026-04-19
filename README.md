# imageengine-kube-helm

Helm chart repository for [ImageEngine](https://imageengine.io) Kube — the
self-hosted, Kubernetes-native image optimization and delivery platform from
[ScientiaMobile](https://www.scientiamobile.com).

The chart is published to **`https://kube.imageengine.io/charts`** via GitHub
Pages, and a copy of the index is also reachable at
`https://imgeng.github.io/imageengine-kube-helm/charts/`.

## Install

```bash
helm repo add imageengine https://kube.imageengine.io/charts
helm repo update
helm install imageengine imageengine/imageengine-kube -f imageengine-values.yaml
```

> An active ImageEngine Kube trial or subscription is required — the chart
> pulls images from `docker.scientiamobile.com` using your API key and
> authenticates to the ImageEngine control plane with the same key. Sign up at
> [imageengine.io](https://imageengine.io).

For the full quick-start, provider presets, customization options, and
troubleshooting, see [`charts/imageengine-kube/README.md`](charts/imageengine-kube/README.md)
and the docs under [`charts/imageengine-kube/docs/`](charts/imageengine-kube/docs/).

## Verifying chart signatures

Every chart `.tgz` is GPG-signed with key `releases@imageengine.io`
(fingerprint `C3A5 5111 ED91 FEDE 4A82 A4B4 4632 6606 0957 C4B3`). The public
key is published at
[`https://kube.imageengine.io/charts/pubkey.asc`](https://kube.imageengine.io/charts/pubkey.asc),
and a `.prov` provenance file is published alongside every release.

See the chart's [Verifying the chart signature](charts/imageengine-kube/README.md#verifying-the-chart-signature-optional)
section for a step-by-step.

## Releases and source

- **Releases:** see [Releases](../../releases) — each tagged release has a
  signed `.tgz` package as an asset, mirrored to the `gh-pages` branch.
- **Source of truth:** the canonical chart source is maintained in a private
  ScientiaMobile monorepo and mirrored here on every release. Issues, feature
  requests, and pull requests against the chart are still welcome in **this**
  repo — they will be triaged and ported upstream as appropriate.

## Repository layout

```
charts/imageengine-kube/   # the chart itself: templates, values, docs
.github/workflows/         # chart-releaser-action release pipeline
```

The `gh-pages` branch hosts the served Helm repo: `index.yaml`, signed `.tgz`
packages and `.prov` files, the public key, and the landing page.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
