# Customizations

A guided tour of the overrides, organized by the question you're trying to answer. Snippets are chart values you'd put in your `imageengine-values.yaml` and pass with `helm install -f imageengine-values.yaml`.

This doc covers the **most common** knobs. The full set of options — including every tunable env var per component — lives in the comments of `values.yaml`. To see the version you'll install, run `helm show values imageengine/imageengine-kube`, or browse the chart source on GitHub at [`imgeng/imageengine-kube-helm`](https://github.com/imgeng/imageengine-kube-helm/blob/main/charts/imageengine-kube/values.yaml). When in doubt, look there.

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

- **Varnish** holds the high-performance in-memory cache of optimized images. Restarting it (whether from a chart upgrade, a `replicaCount` change, an `env`/`resources` edit, or a rollout) **empties that cache**, and the next wave of requests has to refill it from the backend. The edge proxies to a single Varnish endpoint with no consistent hashing, so **adding replicas lowers your hit ratio** (each pod caches an overlapping random subset). Keep `varnish.replicaCount: 1` and treat Varnish as a long-lived component — change it only when you actually need to. Resilience comes from `varnish.priorityClassName` and graceful drain, not replication (see [`How do I protect the cache tiers from disruption?`](#how-do-i-protect-the-cache-tiers-from-disruption)). See also [`How do I tune Varnish storage?`](#how-do-i-tune-varnish-storage).
- **Object Storage Cache** runs as a **sharded StatefulSet** (`objectStorageCache.replicaCount` = number of shards, default 4). Each shard is an independent OSC node with its own PersistentVolume, and clients consistent-hash the origin key across shards, so each shard owns a disjoint slice of the keyspace. Scaling shards is safe and online — see [`How do I size and scale the OSC shards?`](#how-do-i-size-and-scale-the-osc-shards).

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

**Don't autoscale the Object Storage Cache.** Shard count is a deliberate capacity decision (each shard owns a fixed slice of the keyspace and its own volume), not something to flex automatically on CPU. Set `objectStorageCache.replicaCount` explicitly — see [`How do I size and scale the OSC shards?`](#how-do-i-size-and-scale-the-osc-shards).

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

Note: **none of the chart's components set a CPU limit** by default — only CPU requests. This is a chart-wide policy. The Go-based components (edge, backend, fetcher, processor, OSC) would otherwise hit the Go GOMAXPROCS / CFS-throttling pitfall (Go caps concurrency from the cgroup CFS quota); Varnish and rsyslog (C-based) skip CPU limits because bursty workloads are better served by scheduler fair-share than by hard kernel throttling. Don't add a CPU limit to any component unless you have a specific reason — see the "Component Resources" comment block at the top of the components section in [`values.yaml`](https://github.com/imgeng/imageengine-kube-helm/blob/main/charts/imageengine-kube/values.yaml) for the full rationale.

## How do I make the OSC bigger or use a specific storage class?

`persistence.size` is the size of **each shard's** volume. Total cache capacity is roughly `size * replicaCount`.

```yaml
objectStorageCache:
  replicaCount: 4               # number of shards
  persistence:
    size: "256Gi"              # per shard -> ~1Ti total across 4 shards
    storageClass: "gp3"
```

If `provider:` is set, the right storage class is picked automatically — `storageClass: ""` keeps the preset. Setting it explicitly always wins. See [SIZING.md](SIZING.md) for OSC sizing guidance (TL;DR: bigger and faster than you think).

Each shard's PVC is `ReadWriteOnce`, so a shard is pinned to whichever node/AZ owns its volume; on reschedule it reattaches the same volume in that AZ.

## How do I size and scale the OSC shards?

OSC runs as a StatefulSet of `objectStorageCache.replicaCount` shards (default **4**). Each shard (`<release>-osc-0`, `-osc-1`, ...) is an independent OSC node with its own volume, and the backend/fetcher/processor use the OSC sharding client to consistent-hash the **origin key** (Google Jump Consistent Hash) across them. Benefits of sharding by default:

- **Bounded blast radius:** losing one shard only affects ~`1 / replicaCount` of *cache-miss* traffic (those keys recompute from origin), not the whole cache. With the default 4, that's ~25%.
- **No write races:** each shard owns a disjoint slice of the keyspace on its own volume, so there is never more than one writer per object.
- **Cheap, online scaling.** To change shard count, set `replicaCount` and `helm upgrade`:

```yaml
objectStorageCache:
  replicaCount: 6              # was 4
```

Scaling **up** adds higher ordinals (`osc-4`, `osc-5`) with fresh volumes; existing shards keep their data. Consistent hashing means only ~`added / total` of keys remap to the new shards (the rest stay warm); remapped keys take a one-time miss and refill, and orphaned copies on the old shards age out via the expirer. The client picks up the new topology when the backend/fetcher/processor pods roll during the upgrade. A reschedule or restart of a single shard needs no client restart — the stable headless DNS name plus the client's reconnect/retry handle it.

For tiny or dev installs you can drop to `replicaCount: 1` (single node, equivalent to the legacy layout) or `2`. See [SIZING.md](SIZING.md) for per-tier guidance.

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

Full list of varnishd parameters and storage options lives in the comments of [`values.yaml`](https://github.com/imgeng/imageengine-kube-helm/blob/main/charts/imageengine-kube/values.yaml), in the `varnish:` block.

## How do I protect the cache tiers from disruption?

The cache tiers (OSC and Varnish) support three provider-agnostic controls. These guard against *voluntary* disruptions (node drains, autoscaler scale-down, rolling node upgrades) and speed up rescheduling; they do not — and cannot — prevent hard node failures.

**PodDisruptionBudgets** are honored by `kubectl drain`, cluster-autoscaler, and Karpenter alike:

```yaml
objectStorageCache:
  pdb:
    enabled: true          # default; with >=2 shards, cycles one shard at a time
    maxUnavailable: 1

varnish:
  pdb:
    enabled: false         # default off (see trade-off below)
    minAvailable: 1
```

Note the Varnish trade-off: with a single replica, `minAvailable: 1` blocks node drains entirely (a drain will hang until forced). That's strong protection, but enable it deliberately. OSC's `maxUnavailable: 1` only bites once you run 2+ shards.

**Graceful drain** for Varnish lets in-flight requests finish and endpoints deregister before shutdown:

```yaml
varnish:
  terminationGracePeriodSeconds: 30
  drainSeconds: 5          # preStop sleep; set 0 to disable the hook
```

**PriorityClasses** make the cache tiers preempted-last and rescheduled-first. They're cluster-scoped, so creation is opt-in:

```yaml
priorityClass:
  create: true             # creates the two classes below
  oscValue: 1000000
  varnishValue: 900000

objectStorageCache:
  priorityClassName: "imageengine-osc-critical"
varnish:
  priorityClassName: "imageengine-varnish-high"
```

If your org already manages PriorityClasses, leave `priorityClass.create: false` and just set each component's `priorityClassName` to an existing class.

Because ImageEngine recomputes from origin on an OSC miss and the OSC write-back is asynchronous, a shard reschedule is a non-event for end users — so you generally don't need to make OSC drain-blocking. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md#an-osc-shard-restarted--rescheduled).

## How do I tune the edge cache?

Edge ships a per-image natural-width LRU and clamps backend TTLs:

```yaml
edge:
  env:
    EDGE_MAX_TTL: 604800            # 7 days, in seconds
    EDGE_WIDTH_CACHE_SIZE: "10000000"
```

Both have sensible defaults; only touch them if you have a specific reason.

## How do I control the edge access logs?

The edge proxy emits a structured JSON **access log** (one line per request). The sink is a single DSN, `EDGE_ACCESS_LOG_TARGET` (ADR 0008) — it governs the access log **only**; diagnostics always go to the pod's stderr regardless:

```yaml
edge:
  env:
    EDGE_ACCESS_LOG_TARGET: stdout   # stdout | stderr | none | tcp://host:port?format=ndjson|syslog
```

| Value    | Where access logs go                                                            |
| -------- | ------------------------------------------------------------------------------- |
| `stdout` | The pod's stdout — what you see in `kubectl logs deploy/...-edge`. **Default.** |
| `stderr` | The pod's stderr.                                                               |
| `none`   | Access logging is disabled entirely.                                             |
| `tcp://host:port?format=ndjson` | Streams newline-delimited JSON to a TCP collector (Vector / Logstash `json_lines` / Fluentd). |
| `tcp://host:port?format=syslog` | RFC-framed JSON to an rsyslog/syslog-ng TCP listener, e.g. `tcp://<release>-rsyslog:514?format=syslog`. |

The hostless values (`stdout`/`stderr`/`none`) may be written bare or with a trailing colon (`stdout` ≡ `stdout:`). This is why you see JSON lines on the edge pod's stdout out of the box: `EDGE_ACCESS_LOG_TARGET` defaults to `stdout`.

**Field schema — `EDGE_ACCESS_LOG_SCHEMA`.** Independent of the target above, this selects the record's *field set*:

| Value    | Fields                                                                          |
| -------- | ------------------------------------------------------------------------------- |
| `ecs`    | ECS-style record (`@timestamp`, `event.*`, `url.*`, `http.*`, plus an `imageengine.*` namespace) — recognized by Loki/Elastic/Datadog/OTel with no ImageEngine-specific config. **Default.** |
| `legacy` | The historical ie-varnish-logger field set. Transitional — for parity with the SaaS deployment during migration; slated for removal. |

Leave the default `ecs` for new deployments; set `legacy` only if you already have pipelines built on the old field names. The two axes compose — e.g. `EDGE_ACCESS_LOG_SCHEMA: ecs` with `EDGE_ACCESS_LOG_TARGET: "tcp://collector:5140?format=ndjson"`.

**Set `EDGE_ACCESS_LOG_TARGET: none` for high-traffic load tests and production** unless you are actually ingesting these logs somewhere. Access logs are one line per request, so at scale they add real I/O, CPU, and log-storage cost for no benefit if nothing is reading them. Logs are written asynchronously off a buffered channel — if the sink can't keep up (or a `tcp` collector is slow/unreachable), the `edge_access_log_dropped_total` Prometheus metric climbs, which is another signal to switch to `none`.

Notes: a malformed target fails edge startup, and a reachable-but-down `tcp` collector disables access logging with a warning (there is **no** stdout fallback, so a collector outage never floods the pod logs). A `tcp://…?format=syslog` target aimed at the chart's bundled rsyslog aggregator only reaches a downstream collector if `rsyslog.forwarder` is set — the chart default is `discard` (see [SIZING.md](SIZING.md)). `otlp` is reserved for a future native OpenTelemetry Logs exporter.

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

- **`type: LoadBalancer`** (default): the cloud LB controller provisions a public IP and traffic flows directly into the chart. Use `service.annotations` for cloud-LB-specific tuning (LB name, NLB type, ACL annotations, etc. — see your provider doc ([AWS](providers/AWS.md), [Azure](providers/AZURE.md), [DigitalOcean](providers/DIGITALOCEAN.md), [GKE](providers/GKE.md), [Linode](providers/LINODE.md), or [self-managed](providers/CUSTOM.md)) for the right keys).
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

The Ingress is rendered by [templates/ingress.yaml](https://github.com/imgeng/imageengine-kube-helm/blob/main/charts/imageengine-kube/templates/ingress.yaml) and routes all hosts to the edge Service. Provider-specific TLS guidance is in your provider doc.

## How do I use my own image-pull secret name?

If your org's convention has you naming it something other than `ie-kube-image-pull`:

```yaml
secrets:
  imagePullSecretName: "my-organization-pull"
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

## How do I enable distributed tracing (OpenTelemetry)?

Tracing is **opt-in and disabled by default** (ADR 0007). When off, every component runs a no-op tracer with zero overhead and no egress. ImageEngine is trace-store-agnostic: it emits standard OTLP and does **not** bundle or require a collector or backend — you point it at your own.

```yaml
otel:
  enabled: true
  # OTLP/gRPC endpoint. Leave empty to rely on the OpenTelemetry Operator's
  # cluster-wide injection (or the SDK default, localhost:4317).
  endpoint: "http://otel-collector.observability:4317"
  env:
    # ~1-5% is typical in production; non-prod can stay at 100% (the default).
    OTEL_TRACES_SAMPLER: parentbased_traceidratio
    OTEL_TRACES_SAMPLER_ARG: "0.05"
```

This flips on the `*_OTEL_ENABLED` flag for all five Go components (edge, backend, fetcher, processor, OSC), so one client request stitches `edge → backend → {OSC, fetcher, processor}` into a single trace. Varnish is a pure cache and is not instrumented — it passes trace context through on a miss.

`deployment.environment` is set for you from `imageengine.environment`, so traces are tagged with your environment out of the box. Everything under `otel.env` is passed through verbatim as SDK-native `OTEL_*` vars (sampler, resource attributes, etc.); set your own `OTEL_RESOURCE_ATTRIBUTES` there to override the default.

### Restricting OTLP egress with a NetworkPolicy

If your cluster runs a **default-deny egress** posture, enable the bundled NetworkPolicy so the pods can reach your collector:

```yaml
otel:
  enabled: true
  networkPolicy:
    enabled: true
    otlpPort: 4317   # OTLP/gRPC default
```

**Only enable this in a cluster that already has default-deny egress** with separate policies for the pods' other traffic (origins, OSC, emitter, CoreAPI). Kubernetes egress policies are additive, but a pod flips to "deny everything else" the moment *any* egress policy selects it — so if this were the only egress policy on these pods it would break them. In a cluster with no NetworkPolicies at all, leave it disabled (the default).

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

The bottom of every component block in [`values.yaml`](https://github.com/imgeng/imageengine-kube-helm/blob/main/charts/imageengine-kube/values.yaml) is an `env:` map. Anything you put there is injected as an env var on every container of that component:

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

The full set of supported env vars is documented in the inline comments of [`values.yaml`](https://github.com/imgeng/imageengine-kube-helm/blob/main/charts/imageengine-kube/values.yaml) — there are far too many to list here.

## Next

- [SIZING.md](SIZING.md) — how to choose the right values for your traffic volume.
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — when an override produces an unexpected result.
- Your provider doc for cloud-specific overrides (LB type, ingress controller, TLS): [AWS](providers/AWS.md), [Azure](providers/AZURE.md), [DigitalOcean](providers/DIGITALOCEAN.md), [GKE](providers/GKE.md), [Linode](providers/LINODE.md), [self-managed](providers/CUSTOM.md).
