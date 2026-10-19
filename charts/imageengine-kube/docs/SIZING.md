# Sizing

Three rough deployment tiers and starting-point footprints. **These are starting points to benchmark from, not throughput contracts or platform ceilings.** Chart defaults are a compact evaluation footprint; high-traffic deployments intentionally override them. This guide is synchronized with the chart 1.10.0 `values.yaml`; verify the defaults for the version you install. Real throughput depends heavily on:

- Image sizes and formats coming from your origins.
- The mix of transformations being requested.
- Cache hit rates at the Varnish and OSC layers.
- Origin RTT and origin throughput.
- Whether you're serving small thumbnails or large images.

Re-measure after deploying.

## The components

Before picking a tier, it helps to know what each piece of the pipeline does and what it's sensitive to. That's what should drive how you allocate resources.

The chart deploys six components. They sit on the request path in roughly this order:

```
LoadBalancer -> edge -> varnish -> backend -> fetcher  -> origin
                                           -> processor
                                           -> osc
```

Each component emits its own structured JSON logs to stdout/stderr (ADR 0009) — collect them
with your cluster's own node agent (Fluent Bit, Vector, Grafana Alloy, Datadog, or an
OpenTelemetry Collector); the chart no longer bundles a syslog aggregator.

Each section below covers what the component does, how it behaves under load, and the defaults it ships with.

**Chart-wide note on CPU limits:** every component in this chart sets CPU **requests** but not CPU **limits**, by design. For the Go-based components (edge, backend, fetcher, processor, OSC) this avoids the Go GOMAXPROCS / CFS-throttling pitfall — the Go runtime reads the cgroup CFS quota and caps `GOMAXPROCS` to it, artificially limiting concurrency regardless of node capacity. Varnish (C-based) skips CPU limits for the simpler reason that bursty workloads are better served by scheduler fair-share than by hard kernel throttling. **Don't add a CPU limit to any component** unless you have a specific reason and have thought through both effects. See the "Component Resources" comment block at the top of the components section in [`values.yaml`](https://github.com/imgeng/imageengine-kube-helm/blob/main/charts/imageengine-kube/values.yaml).

### Edge

**What it does:** Go entry proxy with WURFL device detection, request policy, admission control and **deterministic routing to Varnish shards**. Edges also maintain an in-memory natural-width cache. With opt-in Edge Warm Start, replicas share newly learned width metadata and a replacement can bootstrap from a peer; **this synchronizes metadata, not image bytes**.

**How it scales:** Edge replicas can scale independently of the number of Varnish shards. There is **no 1:1 edge/Varnish requirement**: the chart's default is one edge and three HRW-sharded Varnish pods. Size edges for request volume, connections, device lookup, memory and availability. Edge HPA is **not shipped**; set `edge.replicaCount` deliberately.

**Defaults:** 1 replica; 256 MiB memory / 250m CPU requests, 1 GiB memory limit. Warm Start is **off** by default and is useful across rollouts/evictions with two or more edges. No CPU limit (chart-wide policy).

#### Edge memory and the natural-width store

Each edge pod keeps an in-memory LRU of the natural (original) width of every origin image it has seen, so it can stop asking for a resize wider than the original. Its capacity is `edge.env.EDGE_WIDTH_CACHE_SIZE`, in entries; one entry is one distinct origin image. The store only grows: it fills with each new image the pod sees and stays full once it reaches capacity, evicting the least recently used. A pod that runs for days on a large image catalogue therefore ends up at capacity, and its memory limit has to cover a full store. A container restart empties the store; it is a cache, so nothing is lost but the pod's knowledge of widths, which it relearns from traffic. With Edge Warm Start (`edge.warmStart.enabled`, [CUSTOMIZATIONS.md](CUSTOMIZATIONS.md#how-do-i-turn-on-edge-warm-start)) a new or restarted edge copies its peers' store instead, so it reaches their size within seconds of starting: size the store for a full one from day one. Sync adds about 24 MB per edge for its log of recent widths.

Plan edge memory as:

```
memory ≈ 400 MiB baseline + EDGE_WIDTH_CACHE_SIZE × 180 bytes
```

- **Baseline (~400 MiB):** the edge process without the store, including the WURFL device-detection data. Busier pods use somewhat more for connections and buffers.
- **180 bytes per entry:** about 110 bytes of live data (key, value, LRU list node and hash-map slot) plus the headroom Go's garbage collector leaves before it collects (`GOGC=100`), measured on a full store.
- **The edge's garbage collector follows its memory limit** (edge 4.12.0 and later). The edge sets its Go memory limit to 90% of the container's limit, less the memory outside the Go runtime (mostly the WURFL device-detection data, 180-290 MiB), and recomputes it every minute, so it also follows an in-place resize. Near that limit the collector runs more often instead of letting the heap grow, which keeps a busy edge out of `OOMKilled`. It doesn't cap memory: a store too big for the limit still runs out, after a stretch of high GC CPU. An explicit `GOMEMLIMIT` in `edge.env` overrides it.
- Keep the result at or below **85% of `limits.memory`**. Past the limit the kernel kills the container (`OOMKilled`) and the store starts empty again. The chart checks this: `helm install` and `helm upgrade` fail with the limit to set (or the largest store that fits) when `edge.resources.limits.memory` is below `(400 MiB + EDGE_WIDTH_CACHE_SIZE × 180 bytes) / 0.85`. An unset `EDGE_WIDTH_CACHE_SIZE` counts as the edge's own default, 5,000,000. The check is skipped when the limit isn't in `edge.resources` (for example, set by a LimitRange) or the size comes from a Secret or ConfigMap.

| `EDGE_WIDTH_CACHE_SIZE` | Store when full | Edge total (approx.) | Memory limit |
| ----------------------- | --------------- | -------------------- | ------------ |
| 1,000,000               | ~170 MiB        | ~570 MiB             | 768 MiB      |
| **2,500,000 (default)** | ~430 MiB        | ~830 MiB             | **1 GiB**    |
| 5,000,000               | ~860 MiB        | ~1.25 GiB            | 1.5 GiB      |
| 10,000,000              | ~1.7 GiB        | ~2.1 GiB             | 2.5 GiB      |

Change the size and the limit together:

```yaml
edge:
  env:
    EDGE_WIDTH_CACHE_SIZE: "5000000"
  resources:
    limits:
      memory: "1536Mi"
```

**Is the store big enough?** The edge exports `imageengine_edge_kvcache_entries` and `imageengine_edge_kvcache_capacity` (fill level) and `imageengine_edge_kvcache_evictions_total`. A store that never reaches capacity is big enough, and lowering the size changes nothing but the worst case. Steady evictions with a falling `imageengine_edge_kvcache_lookups_total{result="hit"}` share mean the catalogue outgrows the store; raise both values per the table. Watch `container_memory_working_set_bytes` for the edge container against its limit as the store fills.

**Access logs at scale:** the edge writes a structured JSON access log — one line per request — and `EDGE_ACCESS_LOG_TARGET` defaults to `stdout`. At high request volume this is a real cost (stdout I/O, CPU, and downstream log storage) for no benefit if nothing is ingesting it. **For high-traffic load tests and production, set `edge.env.EDGE_ACCESS_LOG_TARGET: none`** unless you are actively collecting these logs (`stdout`, `stderr`, or a `tcp://…` collector). See [CUSTOMIZATIONS.md](CUSTOMIZATIONS.md) for the full breakdown.

### Varnish

**What it does:** A horizontally sharded hot-object HTTP cache. The edge discovers the Varnish StatefulSet shards and uses **rendezvous (HRW) hashing on image identity** to route an image's variants to a preferred shard. Unlike round-robin replica caching, the normal path does not replicate the whole working set on every pod. A failed shard can cause misses on its failover target; there is no replicated copy of that shard's cache.

**How it scales:** Plan *aggregate cache capacity, hot-set memory, disk I/O and per-shard concurrency*. Add shards for capacity, throughput or a smaller per-shard blast radius, not merely to track edge replicas. Changes to shard count remap a fraction of keys and temporarily increase misses. Do **not** attach an HPA: cold shards appear exactly when traffic is high and deleting warm shards destroys their local cache. A restarted shard's volatile cache is cold, but most refill traffic should be served by the persistent OSC tier.

**Storage:** With `VARNISH_STORAGE: tiered`, small objects use a malloc tier and larger objects use file-backed tiers. The `VARNISH_STORAGE_1: malloc,70%` setting operates on RAM left after the Varnish reserve, not a promise of 70% of total container memory. Every cached object also consumes heap metadata. Larger memory allocations are particularly valuable for a hot working set.

**Defaults in 1.10.0:** **3 shards**; each requests 1 GiB memory, 500m CPU, and 10 GiB ephemeral storage, with a 4 GiB memory limit and 500 GiB ephemeral-storage limit. `varnish.pdb.enabled: true` and `maxUnavailable: 1`. These are small, evaluation-oriented shards; tune memory/disk for production.

**Cache warm-up:** The commonly cited 30–50% hit ratio in the first hour and 80–90% within 24–48 hours are **workload-dependent rules of thumb, not a benchmark**. Avoid promising a universal warm-up curve. Varnish miss traffic often refills from persistent OSC instead of origin or processor.

**What to watch:** Each Varnish shard exposes Prometheus metrics on port 9464:
- **Hits:** `imageengine_varnish_main_cache_hit_total` versus `imageengine_varnish_main_cache_miss_total`.
- **Evictions:** `imageengine_varnish_main_n_lru_nuked_total` and `imageengine_varnish_storage_c_fail_total{tier="tier2"}`.
- **Worker saturation:** `imageengine_varnish_main_threads_limited_total`, `imageengine_varnish_main_sess_dropped_total`, `imageengine_varnish_main_thread_queue_len`.
- **Memory:** `imageengine_varnish_cgroup_memory_anon_bytes` and file cache versus the container/node budget.

See [CUSTOMIZATIONS.md](CUSTOMIZATIONS.md#how-do-i-scale-a-component) and `varnish.replicaCount` in `values.yaml` for the live sharding model.

### Backend

**What it does:** Request orchestrator. For each request the edge can't satisfy from Varnish, the backend decides what's needed: serve a processed variant from OSC, transform an existing origin image via the processor, fetch a fresh origin image via the fetcher, etc. It then dispatches to those components and **buffers the in-flight image bytes in memory** as they move between layers.

**How it scales:** **RAM-heavy** because it holds full image bodies in memory while orchestrating. Under-provisioning backend memory shows up as OOM-kills exactly when traffic spikes — the worst possible time. The defaults already set a generous 6 GiB limit; keep that headroom and only trim if you've measured.

The backend supports HPA on CPU, but in practice memory pressure shows up before CPU pressure on this component.

**Defaults:** 2 replicas; **500 MiB memory / 250m CPU** requests, **2 GiB memory limit** per pod. CPU HPA is available but off by default (maxReplicas 4 until overridden). Increase backend memory for large concurrent images rather than assuming the compact chart setting is a high-traffic recommendation.

### Fetcher

**What it does:** Pulls original images from origin servers — generic HTTP origins, S3, Wasabi, etc. — and streams them onward to the processor and the OSC. Only runs on cache-miss paths.

**How it scales:** **CPU- and bandwidth-bound during miss storms.** Scaling pattern is similar to the processor — give it generous CPU requests and turn on the HPA at non-PoC traffic levels. At high traffic, network bandwidth to your origins becomes a real constraint. Tunables of note: `IE_ORIGINFETCHER_FETCHER_THREADS_FOR_DOMAIN`, `IE_ORIGINFETCHER_MAX_QUEUE_PER_ORIGIN`, `IE_ORIGINFETCHER_FETCHER_CLIENT_DIAL_TIMEOUT`.

**Defaults:** 2 replicas; **500 MiB memory / 250m CPU** requests, **2 GiB memory limit** per pod. CPU HPA is available but off by default (`maxReplicas: 4` unless overridden).

### Processor

**What it does:** Image transformation, optimization and re-encoding. Resize, crop, format conversion (JPEG, WebP, AVIF, JP2, etc.), quality adjustment. Only runs on cache-miss paths — once a variant is processed and stored in OSC, repeat requests don't touch the processor.

**How it scales:** **CPU-bound during misses, and usually the first thing that saturates** when something is wrong (cold cache, big origin push, sudden new device class hitting the edge). Cache hits cost essentially nothing, but a wave of misses pegs processor CPU before any other component shows pressure. Give it generous CPU requests, and at any non-PoC traffic level turn on the HPA with a high `maxReplicas` so it can scale into a miss storm.

Useful tunables when CPU is plentiful but throughput is low: `IE_PROCESSOR_PROCESSINGTHREADS_PER_CORE` (default 1.2 — push toward 1.5 if you have headroom), and `IE_PROCESSOR_VIPS_DISC_THRESHOLD` (default 10 GiB; lower it to push large images through libvips' on-disk path instead of memory).

**Defaults:** 2 replicas; **2400 MiB memory / 800m CPU** requests, **6 GiB memory limit** per pod. CPU HPA is available but off by default (`maxReplicas: 16` unless overridden).

### Object Storage Cache (OSC)

**What it does:** Persistent disk cache for everything: origin images/objects and their metadata **plus** every processed variant the platform has produced recently. The only **persistent** cache tier in the chart — backed by a PVC per shard (Varnish is also a StatefulSet, but its cache is ephemeral). Cache hits here mean the backend can answer without touching fetcher or processor at all.

**How it's deployed:** A **sharded StatefulSet** of `objectStorageCache.replicaCount` shards (default **4**), each an independent OSC node with its own PVC. Clients consistent-hash the origin key across shards, so each shard owns a disjoint ~`1 / replicaCount` slice of the keyspace. Shard count is primarily a working-set, throughput and blast-radius decision. The steady-state keyspace is approximately divided by the shard count; losing one shard makes its share temporarily unavailable in OSC and its misses may need origin fetching and/or reprocessing. The cache is not replicated, so a failure can affect latency and upstream load.

**How it scales:** Wants a **big, fast disk** — sized by total working set, then divided across shards. Sizing is driven by your catalog and how many variants you serve per origin, not by raw req/sec. Variants are typically **~10× smaller than the originals** they came from (smaller dimensions and stronger optimization), so a useful rough formula is:

```
OSC total working set ≈ origin_catalog_size × (1 + variants_per_origin / 10)
per-shard PVC (persistence.size) ≈ OSC total working set / replicaCount  (plus headroom)
```

For example, 1 million origin images at ~2 MB average plus ~20 variants per origin works out to about 2 TiB of originals plus ~4 TiB of variants — call it ~6 TiB total — and the same number holds whether you serve it at 10 req/sec or 1000 req/sec. Across 4 shards that's ~1.5 TiB per shard (size up for headroom). Adjust the `/10` ratio if your real variant-to-origin size ratio is different (e.g. mostly thumbnail variants pull it closer to /20; a few large reformats pull it closer to /5).

OSC IO latency is on the hot path for every cache hit, so a slow storage class hurts everywhere — slow OSC shows up as backend memory pressure (because requests buffer longer) and processor queue growth (because the cache doesn't absorb load fast enough). Use the fastest SSD-class storage class your provider offers; cheap rotational disks will starve the rest of the pipeline.

CPU footprint is small. Memory footprint is moderate (caching metadata, in-flight reads).

**Eviction:** OSC has two complementary cleanup paths:

- A background **TTL expirer** that periodically scans the cache and removes anything whose TTL has elapsed. This runs continuously, regardless of disk pressure. Tune via `OSC_MAX_TTL` (default 90 days) and `OSC_EXPIRER_LOOP_DELAY` (default 5 m between scan passes).
- A **disk-pressure cleaner** that activates when free disk drops to or below `OSC_FS_DISK_FREE_LIMIT_PERC` (chart default 15%) and aggressively deletes items — even un-expired ones — until free disk climbs back up to `OSC_FS_DISK_FREE_TARGET_PERC` (chart default 20%). This is the safety net that keeps the volume from filling completely. Note: `TARGET` must be **higher** than `LIMIT` — they represent free-space thresholds, not used-space, so cleaning *raises* the percentage. If you misconfigure them with `TARGET <= LIMIT`, the application logs a warning and forcibly sets `TARGET = LIMIT + 2`.

`OSC_MAX_TTL` is the main lever you have:

- **Lower it** (e.g. 720h / 30 days) if your catalog is large and you want to bound disk usage at the cost of a lower hit ratio.
- **Raise it** (or leave at the default 90 days) if you have plenty of disk and want to maximize hit ratio.

If the disk-pressure cleaner is firing regularly in your metrics, you're undersized — give the PVC more room rather than relying on the cleaner as a steady-state mechanism.

**Choosing shard count:** Default **4** is a compact starting point for many evaluations — small enough to keep overhead modest, large enough that any one shard owns only ~25% of the keyspace and can be rescheduled almost anytime. Increase shard count to bound per-shard blast radius further or when a single volume would be impractically large (e.g. multi-TiB tiers). Drop to **1–2** for tiny/dev installs. `persistence.size` is **per shard**, so remember total capacity is `size × replicaCount`. Scaling shard count is online and near-minimal-disruption (see [CUSTOMIZATIONS.md → How do I size and scale the OSC shards?](CUSTOMIZATIONS.md#how-do-i-size-and-scale-the-osc-shards)).

**Defaults:** 4 shards, **512 MiB memory / 900m CPU requests per shard, with no configured memory limit**, 10 GiB PVC **per shard** (40 GiB total). Node memory and page-cache capacity must be planned explicitly; the chart intentionally omits an OSC memory limit. Tunables: `objectStorageCache.replicaCount` (shard count), `objectStorageCache.persistence.size` (per-shard), `objectStorageCache.persistence.storageClass`, `OSC_MAX_TTL` (default 90 days), `OSC_FS_DISK_FREE_LIMIT_PERC` / `OSC_FS_DISK_FREE_TARGET_PERC` (cleaner thresholds), `OSC_EXPIRER_LOOP_DELAY` (background scanner cadence). Protection knobs (`objectStorageCache.pdb`, `priorityClassName`) are covered in [CUSTOMIZATIONS.md](CUSTOMIZATIONS.md#how-do-i-protect-the-cache-tiers-from-disruption).

### Logging

**What changed (ADR 0009):** this chart no longer bundles a syslog aggregator. The edge's access log (ADR 0008) and the origin fetcher's fetch log both default to structured JSON on **stdout**; backend, fetcher, processor, and OSC diagnostics are also structured JSON, on stderr. Collect all of it with your cluster's own node-level agent (Fluent Bit, Vector, Grafana Alloy, Datadog, or an OpenTelemetry Collector) — no ImageEngine-specific sizing to plan for here.

StatsD emission on backend, fetcher, processor, and OSC is still disabled by default (`*_STATSD_ENABLE: false`). To turn it on, set the relevant `*_STATSD_ENABLE` to `true` and point `*_STATSD_SYSLOG_ADDRESS` at your own syslog-speaking StatsD/metrics receiver — the chart no longer provides one.

## Tier 1 — Low traffic / PoC (<10 req/sec, 100/sec bursts)

The chart defaults are a **functional evaluation starting point**, not a free-tier guarantee and not an estimate of peak architecture scale. This tier does not validate production hit ratio or tail latency.

- Chart 1.10.0 defaults: **1 edge, 3 HRW Varnish shards, 2 backends, 2 fetchers, 2 processors and 4 OSC shards** (or explicitly reduce shard counts for a smaller evaluation).
- Varnish: **1 GiB memory / 500m CPU requests, 4 GiB memory limit per shard**; tiered storage. A test may downsize shard count, but any different shard count will change cache behavior.
- OSC: default **10 GiB PVC per shard** (40 GiB total), enough for smoke testing but not representative of large catalogs.
- Backend/fetcher/processor HPA, Edge Warm Start, PodMonitor and OpenTelemetry are all **off unless enabled**.
- Baseline sum of component **CPU requests is ~8 vCPU**, and **memory requests ~12 GiB**, before Kubernetes/system daemons and sidecars. The OSC has no memory limit, so there is no meaningful finite sum of all container memory limits. Allow headroom for scheduling, cache file pages, pod surges and network I/O.
- Use `kubectl describe nodes` / `kubectl top pods` and your cloud provider's scheduling constraints to verify the actual footprint; a particular number or size of nodes is **not** guaranteed by these defaults.

Do not extrapolate PoC cache hit ratios to a production traffic distribution or CDN mix.

## Tier 2 — Medium traffic (<200 req/sec, 750/sec bursts)

Real traffic justifies redundancy and tuning, but the thresholds above categorize operations rather than impose a product capacity limit.

- **Edge:** start at 2 or more replicas for availability; enable [Edge Warm Start](CUSTOMIZATIONS.md#how-do-i-turn-on-edge-warm-start) to share natural-width metadata. Size `EDGE_WIDTH_CACHE_SIZE` and memory together. **Edge count is independent of Varnish shard count.**
- **Varnish:** start from the chart's 3 HRW shards. Increase per-shard RAM substantially when a larger hot set demands it (e.g. requests 4–8 GiB, limits 12–16 GiB) or add shards after measuring per-shard cache capacity and concurrency. Do not use an HPA.
- **Backend:** consider 3–4 replicas and greater memory limits (the chart's default is 2 GiB per pod, not 6 GiB). Size against images buffered in flight.
- **Fetcher:** start at 3–4 replicas with CPU HPA enabled; measure origin concurrency and bandwidth, and raise `maxReplicas` if necessary.
- **Processor:** start at 3–4 replicas with CPU HPA enabled (target 80%, default `maxReplicas: 16`) and benchmark format- and image-size-specific throughput.
- **OSC:** size 4 or more shards with total PV space estimated from the original catalog and derivative working set (often hundreds of GiB or TiB). Favor SSD-backed storage and measure IOPS, IO queueing, and background eviction.
- **Node footprint:** distribute edge, Varnish, processing and OSC according to resource pressure. Do not infer schedulability from aggregate CPU/RAM alone; per-pod requests, node/AZ placement and storage topology also matter.

Turn on your monitoring pipeline and set alerts for shard saturation, hit ratio, OSC disk pressure, processor queues and backend memory occupancy.

## Tier 3 — High traffic (>200 req/sec, >750/sec bursts)

Size from a real trace and your own measured hit ratio, not a generic limit. An entirely cached workload and a new-variant/miss-heavy workload at identical incoming RPS put **very different** loads on the expensive downstream tiers.

- **Edge:** start with multiple replicas for availability; use Warm Start where appropriate. Scale manually after measuring edge CPU, connections, admission and natural-width-store misses. Edge HPA is not shipped.
- **Varnish:** keep an intentionally stable shard count sized for the hot working set and peak throughput; consider more HRW shards and per-shard RAM (8–32 GiB+ where justified), with dedicated nodes/local disk I/O. Adding shards is online but temporarily remaps a fraction of keys to cold shards.
- **Backend:** use CPU HPA and generous memory for concurrently buffered full images; verify actual peak memory and response latency under slow OSC/origin.
- **Fetcher:** CPU HPA with measured origin bandwidth and per-origin concurrency; raise HPA max if benchmarks require it. Protect origins against miss storms.
- **Processor:** CPU HPA with a measured max beyond 16 if warranted, dedicated compute-oriented/arm64 node pools where economical, format-specific profiling and right-sized memory.
- **OSC:** more HRW shards (often 6–8+ for large working sets) and suitably sized SSD-class PVs to spread capacity and aggregate I/O. A lost shard causes additional miss/rehydration traffic; run failure tests and ensure storage/AZ rescheduling fits your recovery objectives.
- **Regional deployments:** for geographically distributed audiences, use [TOPOLOGIES.md](TOPOLOGIES.md) for regional frontend-only releases sharing a **private** backend stack. This does not replicate OSC to each region.

Benchmark normal, cold-start, rolling-upgrade, shard-loss and origin-slowdown behavior. Report p50/p95/**p99/p99.9**, origin fetches and processor jobs per 1,000 requests, layer-specific hit ratios, and per-tier CPU/memory/storage/I/O. Do not market a maximum RPS or linear scale factor without measured results.

## Cross-cutting notes

- **Use arm64 nodes where your provider offers them.** arm64 is fully supported and gives the best price/performance at every tier, with the biggest payoff on the CPU-bound processor. The vCPU and memory figures above apply to either architecture. See [REQUIREMENTS.md](REQUIREMENTS.md#cpu-architecture) and your provider doc for node types.
- **Look at Varnish hit ratio before scaling anything downstream.** A small hit-ratio improvement is usually worth more than doubling a downstream component.
- `**replicaCount` is ignored** for components where `autoscaling.enabled: true` — the HPA owns it. Set `autoscaling.minReplicas` instead.
- **Bench at realistic traffic** before locking in sizing. PoC traffic levels do not predict production cache behavior at all.

## Next

- [CUSTOMIZATIONS.md](CUSTOMIZATIONS.md) — exactly which values to set for replicas, resources, autoscaling, Varnish storage, etc.
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — when sizing turns out to be wrong.

