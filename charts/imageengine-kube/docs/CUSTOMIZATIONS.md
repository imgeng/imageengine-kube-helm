# Customizations

A guided tour of the overrides customers actually use, organized by the question you're trying to answer. Snippets are chart values you'd put in your `imageengine-values.yaml` and pass with `helm install -f imageengine-values.yaml`.

This doc covers the **most common** knobs. The full set of options — including every tunable env var per component — lives in the comments of `values.yaml`. To see the version you'll install, run `helm show values imageengine/imageengine-kube`, or browse the chart on [Artifact Hub](https://artifacthub.io/packages/helm/imageengine-kube/imageengine-kube). When in doubt, look there.

## How do I scale a component?

Set `replicaCount` on the component:

```yaml
edge:
  replicaCount: 3

backend:
  replicaCount: 4

processor:
  replicaCount: 4
```

`replicaCount` applies to `edge`, `varnish`, `backend`, `fetcher`, `processor`, `objectStorageCache`, and `rsyslog`.

If a component has autoscaling enabled (see below), `replicaCount` is **ignored** in favor of `autoscaling.minReplicas`.

A few components have important constraints:

- **Varnish** holds the high-performance in-memory cache of optimized images. Restarting it (whether from a chart upgrade, a `replicaCount` change, an `env`/`resources` edit, or a rollout) **empties that cache**, and the next wave of requests has to refill it from the backend. Treat Varnish as a long-lived component — change it only when you actually need to. See [`How do I tune Varnish storage?`](#how-do-i-tune-varnish-storage) below for the same warning in context.
- **Object Storage Cache** must run as **exactly one replica** in this chart. Running more than one OSC pod splits the cache: each pod stores a different subset of images, and any request that hits the "wrong" pod is treated as a miss and re-fetched from the origin. Don't override `objectStorageCache.replicaCount` above 1. **OSC sharding (multi-replica OSC with consistent hashing) is on the ImageEngine Kube roadmap for 2026.**

## How do I autoscale on CPU?

The `backend`, `fetcher`, and `processor` components support a built-in HorizontalPodAutoscaler:

```yaml
processor:
  autoscaling:
    enabled: true
    minReplicas: 3
    maxReplicas: 16
    targetCPUUtilizationPercentage: 80
```

Same shape for `backend.autoscaling` and `fetcher.autoscaling`.

The HPA only scales on CPU utilization. For why those three components are the right ones to autoscale, see [SIZING.md](SIZING.md).

**Don't autoscale Varnish.** Adding pods (or letting an HPA scale them out and back in) means new pods start with an empty cache, and pods that get scaled down take their warm cache with them. Either way you end up with a colder fleet right when you wanted more capacity. Set `varnish.replicaCount` to a steady value sized for your peak traffic instead.

**Don't autoscale the Object Storage Cache.** It has to stay at one replica — see the constraint above.

## How do I change resource requests / limits?

Every component has the standard Kubernetes shape:

```yaml
processor:
  resources:
    requests:
      memory: "2Gi"
      cpu: "1"
    limits:
      memory: "8Gi"
      cpu: "4"

backend:
  resources:
    requests:
      memory: "2Gi"
      cpu: "500m"
    limits:
      memory: "8Gi"
```

Note: **none of the chart's components set a CPU limit** by default — only CPU requests. This is a chart-wide policy. The Go-based components (edge, backend, fetcher, processor, OSC) would otherwise hit the Go GOMAXPROCS / CFS-throttling pitfall (Go caps concurrency from the cgroup CFS quota); Varnish and rsyslog (C-based) skip CPU limits because bursty workloads are better served by scheduler fair-share than by hard kernel throttling. Don't add a CPU limit to any component unless you have a specific reason — see the "Component Resources" comment block at the top of the components section in `values.yaml` for the full rationale.

## How do I make the OSC bigger or use a specific storage class?

```yaml
objectStorageCache:
  persistence:
    size: "1Ti"
    storageClass: "gp3"
```

If `provider:` is set, the right storage class is picked automatically — `storageClass: ""` keeps the preset. Setting it explicitly always wins. See [SIZING.md](SIZING.md) for OSC sizing guidance (TL;DR: bigger and faster than you think).

The OSC PVC is `ReadWriteOnce`, so OSC pods are pinned to whichever node owns the volume.

**Run exactly one OSC pod.** This chart does not support sharding the OSC across multiple replicas — every request has to land on the same pod for the cache to behave correctly. Running more than one OSC means each pod ends up with a different subset of images, every request to the "wrong" pod is treated as a miss and re-fetched from the origin, and your effective hit ratio collapses. Leave `objectStorageCache.replicaCount` at 1. Sharding support (multi-replica OSC with consistent hashing across pods) is on the ImageEngine Kube roadmap for 2026.

## How do I trade OSC disk usage against hit ratio?

The main lever is `OSC_MAX_TTL` — how long an item is allowed to live in OSC before the background expirer evicts it.

```yaml
objectStorageCache:
  env:
    # Default is 2160h (90 days). Lower it to reduce disk usage; raise it for a
    # higher hit ratio (at the cost of more disk).
    OSC_MAX_TTL: 720h           # 30 days
```

The disk-pressure cleaner (which forcibly evicts when free space gets tight) is also tunable:

```yaml
objectStorageCache:
  env:
    # The cleaner triggers when free disk falls to or below LIMIT,
    # and runs until free disk reaches TARGET. TARGET must be > LIMIT.
    # Chart defaults are 15 / 20 (app defaults are 4 / 6).
    OSC_FS_DISK_FREE_LIMIT_PERC: 15
    OSC_FS_DISK_FREE_TARGET_PERC: 25
```

`TARGET` must be **greater** than `LIMIT` — both are free-space percentages, and the cleaner raises free space from below `LIMIT` up to `TARGET`. If you set `TARGET <= LIMIT`, the application silently bumps `TARGET` to `LIMIT + 2` and logs a warning at startup.

If the disk-pressure cleaner runs continuously in your metrics, you're undersized — give the PVC more room rather than relying on the cleaner as a steady-state mechanism. See the OSC section in [SIZING.md](SIZING.md) for the full eviction story.

## How do I tune Varnish storage?

Varnish is a major performance lever. The default is tiered storage with 70% of pod RAM in tier 1 and file-backed tiers 2 and 3.

Heads-up: changing **any** Varnish setting (resources, env vars, replica count, storage strategy) restarts the Varnish pods, **and the in-memory cache is lost on restart**. Plan changes around that — make them outside peak hours and expect a brief period of higher backend load while Varnish refills. Don't autoscale Varnish (see the [autoscaling section](#how-do-i-autoscale-on-cpu) above).

To give Varnish more memory:

```yaml
varnish:
  resources:
    requests:
      memory: "8Gi"
      cpu: "2"
    limits:
      memory: "16Gi"
```

To switch storage strategy entirely:

```yaml
varnish:
  env:
    # All in memory (simplest, but bounded by pod RAM)
    VARNISH_STORAGE: "malloc,12G"

    # Or all on disk
    # VARNISH_STORAGE: "file,/u/cache/varnish.bin,500G"

    # Or keep tiered but resize the file-backed tiers
    # VARNISH_STORAGE: "tiered"
    # VARNISH_STORAGE_1: "malloc,80%"
    # VARNISH_STORAGE_2: "file,/u/cache/varnish-tier2.bin,200G,8K"
    # VARNISH_STORAGE_3: "file,/u/cache/varnish-tier3.bin,100G,128K"
```

Full list of varnishd parameters and storage options lives in the comments of `values.yaml`, in the `varnish:` block.

## How do I tune the edge cache?

Edge ships a per-image natural-width LRU and clamps backend TTLs:

```yaml
edge:
  env:
    EDGE_MAX_TTL: 604800            # 7 days, in seconds
    EDGE_WIDTH_CACHE_SIZE: "10000000"
```

Both have sensible defaults; only touch them if you have a specific reason.

## How do I configure the edge Service?

The chart exposes its edge pods via a single Service whose type you control. The default is `LoadBalancer`, which works out of the box on every supported managed-Kubernetes provider:

```yaml
service:
  type: LoadBalancer       # or ClusterIP, or NodePort
  port: 80
  annotations: {}
  loadBalancerSourceRanges: []
  externalTrafficPolicy: ""
```

Pick one of three exposure modes:

- **`type: LoadBalancer`** (default): the cloud LB controller provisions a public IP and traffic flows directly into the chart. Use `service.annotations` for cloud-LB-specific tuning (LB name, NLB type, ACL annotations, etc. — see your provider doc ([AWS](/kube/providers/aws/), [Azure](/kube/providers/azure/), [DigitalOcean](/kube/providers/digitalocean/), [GKE](/kube/providers/gke/), [Linode](/kube/providers/linode/), or [self-managed](/kube/providers/custom/)) for the right keys).
- **`type: ClusterIP`**: the Service is reachable only inside the cluster. Pair this with `ingress.enabled: true` (below) so an ingress controller you've installed handles external traffic. Common for bare metal / on-prem and for installs that want hostname-based routing or TLS at the ingress layer.
- **`type: NodePort`**: opens a port on every node. Useful for environments without a LB controller and without an ingress installed; rarely the right answer in production.

`loadBalancerSourceRanges` is a CIDR allowlist (only respected when `type: LoadBalancer`). Empty = open to the world.

`externalTrafficPolicy: Local` preserves the client source IP at the cost of uneven distribution across nodes. The default (`""` / `Cluster`) gives smoother load distribution but rewrites source IPs.

## How do I name or annotate the cloud LoadBalancer?

Put the provider's annotations directly under `service.annotations`. Each provider doc lists the keys for that provider; for example on AWS:

```yaml
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-name: my-imageengine-lb
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
```

…or on DigitalOcean:

```yaml
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/do-loadbalancer-name: my-imageengine-lb
    service.beta.kubernetes.io/do-loadbalancer-size-unit: "2"
```

## How do I add an Ingress in front of the Service?

Set `ingress.enabled: true` and provide hostnames. This works alongside any `service.type` — typically you'd pair it with `service.type: ClusterIP` (so external traffic only enters via the ingress controller), but you can also stack an Ingress on top of a LoadBalancer Service if you want both paths.

```yaml
service:
  type: ClusterIP

ingress:
  enabled: true
  className: nginx                  # leave empty to use the provider preset
  hosts:
    - images.example.com
    - images-staging.example.com
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  tls:
    - secretName: images-example-com-tls
      hosts:
        - images.example.com
        - images-staging.example.com
```

The Ingress is rendered by [templates/ingress.yaml](https://artifacthub.io/packages/helm/imageengine-kube/imageengine-kube?modal=template&template=ingress.yaml) and routes all hosts to the edge Service. Provider-specific TLS guidance is in your provider doc.

## How do I use my own image-pull secret name?

If your org's convention has you naming it something other than `ie-kube-image-pull`:

```yaml
secrets:
  imagePullSecretName: "my-org-scientiamobile-pull"
```

You're still responsible for creating the secret with `kubectl create secret docker-registry`. The chart only references it by name.

## How do I tag traffic with my deployment identity?

Every component receives the values under `identity` as environment variables. They flow into stats, logs, and Sentry tags so you can slice telemetry by deployment:

```yaml
identity:
  DEPLOY: blue
  PRODUCT: imageengine
  ENVIRONMENT: production
  HOST_ID: k8s-pod
  PROVIDER: aws
  REGION: us-east-1
  AZ: us-east-1a
```

Add or remove keys freely — anything you put under `identity` becomes an env var on every container.

## How do I send errors to my own Sentry?

```yaml
sentry:
  FRONTEND_DSN: "https://...@sentry.example.com/1"
  BACKEND_DSN: "https://...@sentry.example.com/2"
  FETCHER_DSN: "https://...@sentry.example.com/3"
  PROCESSOR_DSN: "https://...@sentry.example.com/4"
  OSC_DSN: "https://...@sentry.example.com/5"
```

Empty values disable Sentry reporting for that component.

## How do I pin pods to specific nodes?

Every component supports the standard Kubernetes scheduling primitives:

```yaml
processor:
  nodeSelector:
    node-pool: cpu-optimized
  tolerations:
    - key: workload
      operator: Equal
      value: imageengine
      effect: NoSchedule
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            topologyKey: kubernetes.io/hostname
            labelSelector:
              matchLabels:
                app: imageengine-kube
                tier: processor
```

`nodeSelector`, `tolerations`, and `affinity` are available on `edge`, `varnish`, `backend`, `fetcher`, `processor`, `objectStorageCache`, and `rsyslog`.

The chart already adds a soft `topologySpreadConstraint` per component so replicas spread across nodes when possible.

## How do I enable Green Web Foundation carbon.txt?

If you've registered your infrastructure with the [Green Web Foundation](https://www.thegreenwebfoundation.org/) and have a verification hash:

```yaml
edge:
  carbontxt:
    enabled: true
    hash: "GWF-..."
    content: |
      [upstream]
      providers = [
          { domain='your-cloud-provider.com', service = 'vps' },
      ]
      [org]
      credentials = [
          { domain = 'your-domain.com', doctype = 'webpage', url = "https://your-domain.com/sustainability/" },
      ]
```

If `content:` is empty, the edge falls back to its built-in carbon.txt. **Use your own hash** — using another organization's hash falsely attributes your traffic to their infrastructure.

## Component env vars

The bottom of every component block in `values.yaml` is an `env:` map. Anything you put there is injected as an env var on every container of that component:

```yaml
processor:
  env:
    IE_PROCESSOR_PROCESSINGTHREADS_PER_CORE: "1.5"
    IE_PROCESSOR_VIPS_DISC_THRESHOLD: "5g"

fetcher:
  env:
    IE_ORIGINFETCHER_FETCHER_THREADS_FOR_DOMAIN: "400"

backend:
  env:
    IE_BACKEND_LOGLEVEL: "INFO"
```

The full set of supported env vars is documented in the inline comments of `values.yaml` — there are far too many to list here.

## Next

- [SIZING.md](SIZING.md) — how to choose the right values for your traffic volume.
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — when an override produces an unexpected result.
- Your provider doc for cloud-specific overrides (LB type, ingress controller, TLS): [AWS](/kube/providers/aws/), [Azure](/kube/providers/azure/), [DigitalOcean](/kube/providers/digitalocean/), [GKE](/kube/providers/gke/), [Linode](/kube/providers/linode/), [self-managed](/kube/providers/custom/).
