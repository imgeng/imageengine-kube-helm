# Requirements

The hard minimums for running ImageEngine Kube. If your environment doesn't meet all of these, the install either won't proceed or will misbehave at runtime. For "what should I provision?" guidance instead, see [SIZING.md](SIZING.md).

## Kubernetes

- **Kubernetes 1.30 or newer** (the chart's `kubeVersion` constraint will reject older clusters at install time). **1.33+ is recommended** — as of April 2026, 1.30 / 1.31 / 1.32 are all upstream-EOL. Cloud providers offer paid extended-support tiers for older versions, but new deployments should land on a still-active release.
- **Helm 3.x.** Helm 2 is not supported.

## CPU architecture

- **`linux/amd64` (x86-64) only.** ARM64 (Graviton on AWS, Cobalt on Azure, Axion on GCP, etc.) is **not currently supported** — the arm64 build is experimental and is not shipped in the chart's image tags. Make sure your worker node pools are x86-64.

## Storage

- **A `StorageClass` with dynamic provisioning** that supports `ReadWriteOnce` PersistentVolumeClaims. Only the Object Storage Cache (OSC) needs persistent storage; the chart creates a single PVC for it.
- If you set `provider:` to one of the supported clouds (`aws`, `azure`, `digitalocean`, `gke`, `linode`), the right storage class is picked automatically. Otherwise, set `objectStorageCache.persistence.storageClass` explicitly.
- The OSC needs to be **fast** (the cache is on the hot path for every request that misses Varnish) and **large** (it holds origin images plus every processed variant). 40 GiB is fine for a smoke test; production deployments will want hundreds of GiB to multiple TiB. See [SIZING.md](SIZING.md).

## External access

The chart's edge is exposed via a single Service whose type you choose with `service.type` (rendered by [templates/services.yaml](https://artifacthub.io/packages/helm/imageengine-kube/imageengine-kube?modal=template&template=services.yaml)). The default is `LoadBalancer`, which means **if you keep that default, your cluster must have a working LoadBalancer integration**:

- On managed Kubernetes (EKS / GKE / AKS / DOKS / LKE), the cloud's LB controller is built in.
- On self-managed clusters (bare metal, on-prem, hybrid), install MetalLB or front the cluster with an external load balancer. See [providers/CUSTOM.md](providers/CUSTOM.md).

Without a working LB integration the Service sits in `<pending>` forever and there's no way to reach the edge from outside the cluster. If you don't want a cloud LB at all, set `service.type: ClusterIP` and pair it with an Ingress (`ingress.enabled: true`) so an ingress controller you've installed handles external traffic. See [CUSTOMIZATIONS.md](CUSTOMIZATIONS.md) for the full set of options.

## Network egress

Worker nodes need outbound network access to:

- `https://docker.scientiamobile.com` (image pull for all components).
- `https://control-api.imageengine.io` (origin configuration API consumed by the edge and backend).
- `https://emitter.eleven45.net` (config updates and purges from WebUI).
- The server(s) that ImageEngine Kube will pull your images from.

If your cluster sits behind an egress proxy or strict firewall, allow-list those hosts before installing.

## Pre-existing secrets

The chart references two Kubernetes Secrets by name and **does not create them for you**. They must exist in the install namespace before `helm install` runs:

- `ie-kube-api-key` — opaque secret with key `KEY` set to your ImageEngine API key.
- `ie-kube-image-pull` — `kubernetes.io/dockerconfigjson` for `docker.scientiamobile.com`.

The exact `kubectl create secret` commands are in [GETTING_STARTED.md](GETTING_STARTED.md). The image-pull secret name can be overridden via `secrets.imagePullSecretName` if you'd rather use a name that fits your existing convention.

A third optional secret, `ie-kube-fetcher`, is referenced in `values.yaml` as a place to store cloud-storage credentials (AWS / Wasabi keys) for the fetcher when your origins live in private buckets. It's only needed if you uncomment the corresponding env vars.

## Compute footprint

At default replica counts (1 edge, 1 varnish, 2 backend, 2 fetcher, 2 processor, 1 OSC, 1 rsyslog), the chart asks for roughly:

- **CPU requests:** ~3 vCPU total.
- **Memory requests:** ~10 GiB total.
- **Memory limits (burst ceiling):** ~40 GiB total.

To leave room for OS overhead, system daemons, and burst headroom, plan on **at least 3 worker nodes of 4 vCPU / 8 GiB each** for a comfortable PoC deployment. Smaller node sizes may force pods to fail scheduling because Varnish (1 GiB request, 4 GiB limit) and OSC (2 GiB request, 4 GiB limit) need a non-trivial slice of any one node.

For higher traffic tiers, see [SIZING.md](SIZING.md).

## Next

- [GETTING_STARTED.md](GETTING_STARTED.md) — install once requirements are met.
- [SIZING.md](SIZING.md) — pick a footprint for your traffic.
- Your provider doc for platform-specific prep: [AWS](/kube/providers/aws/), [Azure](/kube/providers/azure/), [DigitalOcean](/kube/providers/digitalocean/), [GKE](/kube/providers/gke/), [Linode](/kube/providers/linode/), [self-managed](/kube/providers/custom/).

