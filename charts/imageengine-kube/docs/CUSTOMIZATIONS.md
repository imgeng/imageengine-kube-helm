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

`replicaCount` applies to `edge`, `varnish`, `backend`, `fetcher`, `processor`, and `objectStorageCache`.

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

Note: **none of the chart's components set a CPU limit** by default — only CPU requests. This is a chart-wide policy. The Go-based components (edge, backend, fetcher, processor, OSC) would otherwise hit the Go GOMAXPROCS / CFS-throttling pitfall (Go caps concurrency from the cgroup CFS quota); Varnish (C-based) skips CPU limits because bursty workloads are better served by scheduler fair-share than by hard kernel throttling. Don't add a CPU limit to any component unless you have a specific reason — see the "Component Resources" comment block at the top of the components section in [`values.yaml`](https://github.com/imgeng/imageengine-kube-helm/blob/main/charts/imageengine-kube/values.yaml) for the full rationale.

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
| `tcp://host:port?format=syslog` | RFC-framed JSON to a syslog-speaking TCP listener, e.g. your own rsyslog/syslog-ng Service. |

The hostless values (`stdout`/`stderr`/`none`) may be written bare or with a trailing colon (`stdout` ≡ `stdout:`). This is why you see JSON lines on the edge pod's stdout out of the box: `EDGE_ACCESS_LOG_TARGET` defaults to `stdout`.

**Field schema — `EDGE_ACCESS_LOG_SCHEMA`.** Independent of the target above, this selects the record's *field set*:

| Value    | Fields                                                                          |
| -------- | ------------------------------------------------------------------------------- |
| `ecs`    | ECS-style record (`@timestamp`, `event.*`, `url.*`, `http.*`, plus an `imageengine.*` namespace) — recognized by Loki/Elastic/Datadog/OTel with no ImageEngine-specific config. **Default.** |
| `legacy` | The historical ie-varnish-logger field set. |

Leave the default `ecs` for new deployments; set `legacy` only if you already have pipelines built on the old field names. The two axes compose — e.g. `EDGE_ACCESS_LOG_SCHEMA: ecs` with `EDGE_ACCESS_LOG_TARGET: "tcp://collector:5140?format=ndjson"`.

**Set `EDGE_ACCESS_LOG_TARGET: none` for high-traffic load tests and production** unless you are actually ingesting these logs somewhere. Access logs are one line per request, so at scale they add real I/O, CPU, and log-storage cost for no benefit if nothing is reading them. Logs are written asynchronously off a buffered channel — if the sink can't keep up (or a `tcp` collector is slow/unreachable), the `edge_access_log_dropped_total` Prometheus metric climbs, which is another signal to switch to `none`.

Notes: a malformed target fails edge startup, and a reachable-but-down `tcp` collector disables access logging with a warning (there is **no** stdout fallback, so a collector outage never floods the pod logs). This chart no longer bundles a syslog aggregator (ADR 0009) — a `tcp://…?format=syslog` target must point at your own syslog-speaking receiver. `otlp` is reserved for a future native OpenTelemetry Logs exporter.

**The origin fetcher has the same DSN + schema pair** for its per-fetch structured log:
`IE_ORIGINFETCHER_FETCH_LOG_TARGET` (same grammar as `EDGE_ACCESS_LOG_TARGET`, default `stdout`)
and `IE_ORIGINFETCHER_FETCH_LOG_SCHEMA` (`ecs` | `legacy`, default `ecs`).

## How do I add a sidecar to the edge pod?

`edge.extraContainers` appends containers to every edge pod. A typical use is a metrics adapter that scrapes the edge's admin listener on `http://localhost:9464/metrics` and forwards the series to a system that does not scrape Prometheus. The list is rendered with `tpl`, so strings can reference chart values:

```yaml
edge:
  extraContainers:
    - name: metrics-adapter
      image: registry.example.com/metrics-adapter:1.0.0
      env:
        - name: SCRAPE_URL
          value: "http://localhost:9464/metrics"
        - name: REGION
          value: "{{ .Values.identity.region }}"
        - name: POD_NAME
          valueFrom:
            fieldRef: { fieldPath: metadata.name }
      resources:
        requests: { cpu: 10m, memory: 32Mi }
        limits: { memory: 64Mi }
  # Only needed when the sidecar image is outside secrets.imagePullSecretName's registry.
  extraImagePullSecrets:
    - my-registry-pull
```

A sidecar shares the edge pod's lifecycle, so it scales with `edge.replicaCount` and each copy sees exactly one edge. If the namespace has a ResourceQuota, give the sidecar requests and limits and grow the quota to match.

## How do I split the frontend and backend across clusters?

By default the chart deploys the whole pipeline (edge → varnish → backend →
{fetcher | processor | OSC}) as one release — this is the normal deployment and
what most installs want. You can instead split it into two independently
deployable tiers and run them as separate releases, e.g. regional frontend
points-of-presence in front of one central backend stack:

```yaml
# Frontend-only release (edge + Varnish); points Varnish at a remote backend LB
frontend:
  enabled: true
backendStack:
  enabled: false
varnish:
  ieBackends: "ie-backend.us-east.internal.example.com"   # required here
```

```yaml
# Backend-only release (backend + fetcher + processor + OSC); publishes the backend
frontend:
  enabled: false
backendStack:
  enabled: true
backend:
  service:
    type: LoadBalancer        # keep it PRIVATE — see the security note in TOPOLOGIES.md
    loadBalancerSourceRanges:
      - 10.0.0.0/8
```

At least one tier must be enabled. A backend `LoadBalancer` carries
unauthenticated admin endpoints over plain HTTP, so it **must** be private or
source-range restricted. The full story — the multi-region diagram, how
`ieBackends` is resolved, health-check and failure behavior, the same-cluster
two-release pattern, and ready-to-use example values files — is in
[TOPOLOGIES.md](TOPOLOGIES.md).

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
- **`type: ClusterIP`**: the Service is reachable only inside the cluster. Pair this with `ingress.enabled: true` or `httpRoute.enabled: true` (below) so an ingress controller or Gateway you've installed handles external traffic. Common for bare metal / on-prem and for installs that want hostname-based routing or TLS at the ingress layer.
- **`type: NodePort`**: opens a port on every node. Useful for environments without a LB controller and without an ingress installed; rarely the right answer in production.

`loadBalancerSourceRanges` is a CIDR allowlist (only respected when `type: LoadBalancer`). Empty = open to the world.

`externalTrafficPolicy: Local` preserves the client source IP at the cost of uneven distribution across nodes. The default (`""` / `Cluster`) gives smoother load distribution but rewrites source IPs. On `gke` and `azure`, leaving it empty with a LoadBalancer sets `Local` (see the next section).

## How do I preserve the client IP?

The edge's fair-share admission control keys on the client IP (together with device form factor and browser family), so one heavy client is throttled before it can crowd out everyone else. The access log records it too. If the IP is lost, every visitor looks like your load balancer or node: they all share one fair-share bucket, and `imageengine_edge_clients_tracked` stays near the number of nodes.

How the edge learns the IP depends on what sits in front of it. `clientIP.mode: auto` (the default) picks from your `provider`, `service.type` and `ingress.enabled`:

| How traffic reaches the edge | `auto` resolves to | What the chart configures |
|---|---|---|
| `ingress.enabled: true` or `httpRoute.enabled: true` | `forwardedFor` | The edge trusts only the `X-Forwarded-For` entries your ingress controller or Gateway (and any L7 load balancer in front of it) appended: 1 hop, or 2 for GCE ingress. |
| LoadBalancer on `aws`, `digitalocean`, `linode` | `proxyProtocol` | The provider's PROXY protocol annotation on the edge Service, and the edge reads the header. |
| LoadBalancer on `gke`, `azure` | `direct` | `externalTrafficPolicy: Local`, and the edge uses the connection's source address. Their standard load balancers do not send PROXY headers. |
| Anything else (`custom`, NodePort, ClusterIP) | `direct` | The edge uses the connection's source address. |

`auto` needs edge 4.10.0 or later; with an older `images.edge` it stays `legacy`. Set the mode yourself when your setup differs from the table:

```yaml
clientIP:
  mode: forwardedFor     # auto | proxyProtocol | forwardedFor | direct | legacy
  forwardedHops: 2       # e.g. a CDN or L7 load balancer in front of your ingress controller
```

- **`proxyProtocol`**: the load balancer prepends the client's address to each TCP connection, and the edge reads it. `clientIP.proxyProtocol.policy: optional` (default) also serves connections without a header, which some load balancers' health checks are; `required` refuses them. On providers without a preset annotation, add your load balancer's own annotation to `service.annotations`.
- **`forwardedFor`**: the client is the entry `forwardedHops` from the right of `X-Forwarded-For`, so anything a client put in the header itself is skipped. Count one hop per proxy that appends to the header between the client and the edge: Traefik, Envoy Gateway and the AWS ALB append one each; GCE ingress and the GKE Gateway controller two. If you front the ingress with an L7 load balancer or CDN, add one for it. If the proxies' addresses are known and stable, `clientIP.trustedProxies` (CIDRs) replaces the hop count: the header is then used only from those peers, and the client is its rightmost entry outside them. The ingress controller or Gateway must itself see the client's address, or it appends a node IP: give its own Service `externalTrafficPolicy: Local`, or enable PROXY protocol between its load balancer and it (for Traefik, the provider's annotation on its Service plus `proxyProtocol.trustedIPs` on its entry points; for Envoy Gateway, the annotation in the `EnvoyProxy`'s `envoyService.annotations` plus `proxyProtocol` in a `ClientTrafficPolicy`).
- **`direct`**: the edge ignores forwarded headers and uses the connection's source address. That is the client only when nothing in between rewrites it, which in Kubernetes usually means `externalTrafficPolicy: Local`.
- **`legacy`**: the edge's behaviour before 4.10.0: the leftmost `X-Forwarded-For` entry, which is whatever the client sent unless a proxy overwrites the header. Only for setups that rely on it.

> **Moving an existing install to `proxyProtocol`.** The load balancer starts sending PROXY headers as soon as the Service annotation changes, but edge pods are replaced one at a time, and an edge that does not expect a header answers 400. Upgrade in two steps: first with `clientIP.proxyProtocol.annotateService: false` (every edge pod then accepts headers, and still serves plain connections), and once the rollout finishes, again with it back at `true`. A fresh install needs neither step.

Two things keep a forged client address out:

- **With `ingress.enabled` or `httpRoute.enabled`, set `service.type: ClusterIP`.** If the edge Service is also a LoadBalancer, clients can reach the edge without passing through the ingress controller or Gateway and send whatever `X-Forwarded-For` they like.
- **With `proxyProtocol`, block the Service's NodePorts on your nodes.** A LoadBalancer Service also opens a NodePort on every node. Where nodes have public IPs, a client connecting to a NodePort directly can send its own PROXY header, and after kube-proxy rewrites the source the edge cannot tell it from the load balancer. Allow the NodePort range (30000-32767 by default) only from the load balancer, with your provider's firewall or security group.

To check what the edge is doing, read `imageengine_edge_client_ip_resolutions_total{result}` from the edge metrics port (9464). `remote_addr` and `forwarded` are normal. A steady rate of `short_forwarded`, `untrusted_peer` or `invalid_forwarded` means `forwardedHops` or `trustedProxies` does not match the path your traffic takes. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md#every-client-shares-one-fair-share-bucket).

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
  className: traefik                # leave empty for the provider preset or the cluster's default IngressClass
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

Which controller serves the Ingress:

- `ingress.className`, when you set it.
- Otherwise the provider preset, on platforms that ship their own controller: `alb` on `aws`, `gce` on `gke`.
- Otherwise the chart sets no class, and the cluster's default IngressClass serves the Ingress. `kubectl get ingressclass` shows which one that is, if any (the one annotated `ingressclass.kubernetes.io/is-default-class: "true"`). With no default and no `className`, no controller picks the Ingress up.

The chart doesn't install a controller. ingress-nginx was retired upstream in March 2026, so for a new cluster pick a maintained one, such as [Traefik](https://doc.traefik.io/traefik/), or route through a Gateway (next section).

## How do I route through a Gateway (Gateway API)?

If your cluster runs a Gateway API implementation (Envoy Gateway, Cilium, Istio, Traefik, or the GKE or DOKS Gateway controllers), the chart can attach an `HTTPRoute` to your Gateway instead of creating an Ingress. The chart creates only the route. The Gateway, its listeners and their TLS certificates stay yours.

```yaml
service:
  type: ClusterIP             # the Gateway is the only way in

httpRoute:
  enabled: true
  parentRefs:
    - name: my-gateway
      namespace: gateway
      sectionName: https      # optional: attach to one listener only
  hostnames:
    - images.example.com      # empty: every hostname the listener accepts
```

- The listener must allow routes from the release's namespace (`allowedRoutes.namespaces` on the Gateway).
- `clientIP.mode: auto` resolves to `forwardedFor` with one hop, which matches Gateways that append the client's address to `X-Forwarded-For`, such as Envoy Gateway. The GKE Gateway controller's load balancer appends two entries, like GCE ingress, so set `clientIP.forwardedHops: 2` there.
- The Gateway must see the client's address itself. Behind a cloud load balancer that usually means PROXY protocol between them (see [How do I preserve the client IP?](#how-do-i-preserve-the-client-ip)).
- The cluster needs the Gateway API CRDs (`gateway.networking.k8s.io/v1`), which every implementation installs or documents.

To check the route, run `kubectl get httproute <release>-httproute -o yaml`: `status.parents` should show `Accepted: True` and `ResolvedRefs: True` for your Gateway.

## How do I serve HTTP/3?

HTTP/3 is a protocol between your clients and your TLS terminator, and nowhere else. The terminator is whatever you put in front of the edge: a CDN, a cloud L7 load balancer, or an ingress controller or gateway in your cluster. Behind it, from the terminator to the edge and between ImageEngine Kube's own components, the chart sets the protocols, and there is nothing to configure. The edge Service takes plain HTTP on port 80.

HTTP/3 runs over QUIC on UDP port 443. Every hop between the client and the terminator therefore has to carry UDP, and the terminator still has to learn each client's real IP address. That is easy when the terminator sits in front of the cluster, and hard when it sits inside the cluster behind a cloud load balancer.

### Why it is hard behind a cloud load balancer

- **Fair-share admission loses the client IP.** This is the main problem. The edge's fair-share admission keys on the client IP (see [How do I preserve the client IP?](#how-do-i-preserve-the-client-ip)). Over TCP, the cloud load balancer sends a PROXY header with the client's address. Over UDP most load balancers can't, and QUIC terminators don't read PROXY headers anyway. Unless the load balancer passes the client's source address through unchanged and the terminator's Service uses `externalTrafficPolicy: Local`, the terminator sees the load balancer's or a node's address and appends that to `X-Forwarded-For`. Every HTTP/3 visitor then shares one fair-share bucket, so throttling meant for one heavy client hits all of them, and the access log loses their addresses. Browsers switch to HTTP/3 once it is advertised, so this can quickly become most of your traffic.
- **TCP and UDP on the same port.** Clients find HTTP/3 through an `Alt-Svc` response header that, in practice, points at the same host and port they used for TCP. The terminator's Service needs both `443/TCP` and `443/UDP` on one IP address, which not every cloud controller can provision.
- **It is advertised before it works.** Terminators send `Alt-Svc: h3=":443"; ma=86400` on TCP responses as soon as HTTP/3 is enabled, whether or not UDP reaches them. Browsers fall back to TCP, but they remember the advertisement for a day and keep retrying it. The same happens if you move a hostname to a load balancer without UDP. Enable HTTP/3 only after UDP works end to end (for example `curl --http3-only` against the load balancer's address).
- **Connection migration needs a QUIC-aware load balancer.** QUIC connections can survive a change of client address, such as moving from Wi-Fi to mobile data. A load balancer that hashes on address and port sends the moved connection to a different pod, which drops it, and the client reconnects. This does no harm, but it removes one of HTTP/3's benefits.

### Recommended: terminate HTTP/3 at a CDN or L7 load balancer

A CDN or cloud L7 load balancer that supports HTTP/3 talks HTTP/3 to clients and adds the client's address to `X-Forwarded-For` before forwarding over TCP. On the cluster side, use `clientIP.mode: forwardedFor` and count one more hop for the CDN, or list its egress ranges in `clientIP.trustedProxies` (see [How do I preserve the client IP?](#how-do-i-preserve-the-client-ip)).

### Terminating HTTP/3 at an ingress controller or gateway in your cluster

You need all of these:

- An ingress controller or Gateway that terminates QUIC, such as Envoy Gateway (`http3` in a `ClientTrafficPolicy`). Check your controller's documentation; many don't offer HTTP/3.
- A cloud load balancer that carries UDP 443 next to TCP 443 on the same address and keeps the client's source address on UDP. The terminator's Service needs `externalTrafficPolicy: Local`.
- The terminator seeing the real client address on both TCP and UDP, so the edge can use `clientIP.mode: forwardedFor` for both.

Check the result before you rely on it. With HTTP/3 traffic flowing, `imageengine_edge_clients_tracked` should be far above your node count (see [TROUBLESHOOTING.md](TROUBLESHOOTING.md#every-client-shares-one-fair-share-bucket)).

### Provider support

We test each provider's load balancer against the requirements above. Providers not listed have not been tested yet. A CDN or L7 load balancer in front of the cluster works on every provider.

| Provider | HTTP/3 at an ingress controller or gateway in the cluster | Why |
|---|---|---|
| `linode` | Not supported | NodeBalancers carry UDP only on Premium NodeBalancers, as a beta feature Akamai enables per account, and can't send PROXY headers over UDP. One Service can't carry TCP and UDP on the same port. See [providers/LINODE.md](providers/LINODE.md#http3). |

## How do I use my own image-pull secret name?

If your org's convention has you naming it something other than `ie-kube-image-pull`:

```yaml
secrets:
  imagePullSecretName: "my-organization-pull"
```

You're still responsible for creating the secret with `kubectl create secret docker-registry`. The chart only references it by name.

## How do I tag traffic with my deployment identity?

Set your deployment identity under `identity:`. These labels flow into stats, logs, traces, and Sentry (as ECS `service.*` / `cloud.*` / `host.*`) so you can slice telemetry by deployment:

```yaml
identity:
  environment: production   # single source of truth: also drives Sentry env + OTel deployment.environment
  deploy: blue
  region: us-east-1
  availabilityZone: us-east-1a
  # product / hostId default to imageengine / k8s-pod
  # provider — follows the top-level `provider` unless set here
  # hostname / hostType / hostImage — optional host.* labels
```

The keys are friendly camelCase names; the chart maps each to the env var the binaries read (`environment` → `ENVIRONMENT`, `availabilityZone` → `AZ`, `hostId` → `HOST_ID`, …). `environment` is the single source of truth for the deployment environment (logs `service.environment`, every component's Sentry env, and OTel `deployment.environment`). `provider` lives at the top level because it also selects infra presets; the provider label follows it unless you override `identity.provider`. For an arbitrary env var on one component, use `<component>.env`.

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

`deployment.environment` is set for you from `identity.environment`, so traces are tagged with your environment out of the box. Everything under `otel.env` is passed through verbatim as SDK-native `OTEL_*` vars (sampler, resource attributes, etc.); set your own `OTEL_RESOURCE_ATTRIBUTES` there to override the default. `otel.env` follows the same scalar-or-map convention as a component's `env` (see [Sourcing an env var from a Secret or ConfigMap](#sourcing-an-env-var-from-a-secret-or-configmap)), so a hosted collector's credential can come from a Secret rather than being inlined:

```yaml
otel:
  enabled: true
  endpoint: "https://otlp.example.com:4317"
  env:
    OTEL_EXPORTER_OTLP_HEADERS:
      secretKeyRef:
        name: otel-collector-auth
        key: headers
```

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

`nodeSelector`, `tolerations`, and `affinity` are available on `edge`, `varnish`, `backend`, `fetcher`, `processor`, and `objectStorageCache`.

In a mixed-architecture cluster you don't need to pin anything, because every image is multi-arch. To keep a component on your arm64 pool anyway (for example, so the processor always gets the better price/performance nodes), select on the standard architecture label:

```yaml
processor:
  nodeSelector:
    kubernetes.io/arch: arm64
```

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

### Sourcing an env var from a Secret or ConfigMap

An `env` entry can be either a **scalar** (rendered as the variable's `value:`) or a
**map** (rendered verbatim as the variable's `valueFrom:`). That lets you pull any
custom env var from a Kubernetes Secret, ConfigMap, or the pod's own metadata
instead of inlining it in `values.yaml` — never commit a secret in plaintext:

```yaml
edge:
  env:
    # Scalar -> value:
    EDGE_LOGLEVEL: "info"
    # Map -> valueFrom.secretKeyRef (pull a secret you created out-of-band)
    EDGE_EMITTER_SERVER_KEY:
      secretKeyRef:
        name: ie-kube-emitter
        key: KEY
    # Map -> valueFrom.configMapKeyRef
    EDGE_ORIGIN_CONF_REFRESH_INTERVAL:
      configMapKeyRef:
        name: edge-tuning
        key: refreshInterval
    # Map -> valueFrom.fieldRef (Downward API)
    EDGE_POD_IP:
      fieldRef:
        fieldPath: status.podIP
```

This is the mechanism behind the `<<SECRET: <secret-name>.<key>>` placeholders
you'll see in the commented-out examples in [`values.yaml`](https://github.com/imgeng/imageengine-kube-helm/blob/main/charts/imageengine-kube/values.yaml)
(e.g. `EDGE_EMITTER_SERVER_KEY: "<<SECRET: ie-kube-emitter.KEY>>"`). To use one,
replace the placeholder with a `secretKeyRef` map as shown above — `<<SECRET: ie-kube-emitter.KEY>>`
means "the `KEY` key of the `ie-kube-emitter` Secret." The chart references these
Secrets by name; you are responsible for creating them in the install namespace
(see [REQUIREMENTS.md](REQUIREMENTS.md)).

The whole map value is passed straight through to the container's `valueFrom:`, so
any field Kubernetes accepts there works — including `optional: true` on a
`secretKeyRef`/`configMapKeyRef` if the source may not exist.

### Overriding a variable the chart already sets

Defining a variable in `env` that the chart also emits would produce a duplicate
name, which breaks `helm upgrade`. Two classes of built-in therefore step aside
when you define them yourself, so you can redefine them freely:

- Anything the chart reads out of one of **its own Secrets** — the ImageEngine API
  key and the fetcher's `ie-kube-fetcher` cloud-storage credentials. Override
  these to keep the value in a Secret you name yourself.
- Anything the chart **derives from a single values key** — `*_SENTRY_DSN`,
  `*_SENTRY_ENV`, `*_EMITTER_SERVER`, `*_EMITTER_*_KEY`, `APP_ENV`, and
  `OSC_FS_STORAGE_PATH`.

Everything else the chart computes **structurally** must not be redefined: in-cluster
service URLs, bind addresses, the `OSC{N}_HOST` shard list, `COMPONENT`, the
deployment identity vars (`ENVIRONMENT`, `PROVIDER`, `REGION`, `AZ`, `DEPLOY`,
`PRODUCT`, `HOST_*`), and the OTel enable flags.

> **Overriding the API key means owning emitter auth.** By default the emitter keys
> are derived from the API key via `$(...)` interpolation, which Kubernetes only
> resolves against a variable defined *earlier* in the container's env list. Your
> own definitions render after the chart's, so if you set the API key
> (`EDGE_API_KEY`, `IE_BACKEND_IMAGEENGINE_API_KEY`, or `IE_KUBE_API_KEY_RAW`) the
> chart omits those derived emitter keys instead of emitting an unresolvable
> reference. Set the corresponding `*_EMITTER_*_KEY` yourself in the same `env` block.

## Next

- [SIZING.md](SIZING.md) — how to choose the right values for your traffic volume.
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — when an override produces an unexpected result.
- Your provider doc for cloud-specific overrides (LB type, ingress controller, TLS): [AWS](providers/AWS.md), [Azure](providers/AZURE.md), [DigitalOcean](providers/DIGITALOCEAN.md), [GKE](providers/GKE.md), [Linode](providers/LINODE.md), [self-managed](providers/CUSTOM.md).
