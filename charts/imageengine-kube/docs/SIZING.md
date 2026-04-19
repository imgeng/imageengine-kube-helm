# Sizing

Three rough deployment tiers and starting-point footprints. **These are starting points to bench from, not contracts.** Real throughput depends heavily on:

- Image sizes and formats coming from your origins.
- The mix of transformations being requested.
- Cache hit rates at the Varnish and OSC layers.
- Origin RTT and origin throughput.
- Whether you're serving small thumbnails or large images.

Re-measure after deploying.

## The components

Before picking a tier, it helps to know what each piece of the pipeline does and what it's sensitive to. That's what should drive how you allocate resources.

The chart deploys seven components. They sit on the request path in roughly this order:

```
LoadBalancer -> edge -> varnish -> backend -> fetcher  -> origin
                                           -> processor
                                           -> osc
                                                       (rsyslog collects logs from all of the above)
```

Each section below covers what the component does, how it behaves under load, and the defaults it ships with.

**Chart-wide note on CPU limits:** every component in this chart sets CPU **requests** but not CPU **limits**, by design. For the Go-based components (edge, backend, fetcher, processor, OSC) this avoids the Go GOMAXPROCS / CFS-throttling pitfall — the Go runtime reads the cgroup CFS quota and caps `GOMAXPROCS` to it, artificially limiting concurrency regardless of node capacity. Varnish and rsyslog (C-based) skip CPU limits for the simpler reason that bursty workloads are better served by scheduler fair-share than by hard kernel throttling. **Don't add a CPU limit to any component** unless you have a specific reason and have thought through both effects. See the "Component Resources" comment block at the top of the components section in `values.yaml`.

### Edge

**What it does:** Go proxy that's the entry point for every request. Performs WURFL device detection (identifies the requesting browser/device so the rest of the pipeline knows what optimization is appropriate), admission control, and routing into Varnish. Stateless — no shared state across replicas.

**How it scales:** Latency-sensitive rather than throughput-sensitive. Scales linearly with request volume. The work it does per request is small (microsecond-level device lookup against an in-memory WURFL cache, then proxy through to Varnish), so even one well-resourced edge pod handles a lot of requests.

**Important:** keep `edge.replicaCount` equal to `varnish.replicaCount`. Edge does the connection-limiting that protects Varnish from overload, and the limits are tuned for a 1:1 ratio — see the Varnish section below for details.

**Defaults:** 1 replica, 256 MiB / 250m CPU requests, 1 GiB memory limit. (No CPU limit — chart-wide policy, see the note above.)

### Varnish

**What it does:** HTTP cache that sits between the edge and the backend. Holds the **current hot set** of already-processed images so most repeat requests never reach the backend. Deployed separately from the edge so the cache survives edge restarts and rolling updates.

**How it scales:** **RAM-hungry.** Small images live entirely in memory — the default tiered storage puts 70% of pod RAM into tier 1 (`malloc`). Medium and large images spill to file-backed tiers 2 and 3 (`VARNISH_STORAGE_2` / `VARNISH_STORAGE_3`). The more RAM you give Varnish, the higher your in-memory hit ratio, which is the single biggest lever for keeping load off the backend, processor, and fetcher.

A 5% Varnish hit-ratio improvement is usually worth more than doubling any downstream component.

**Cache warm-up curve:** an empty Varnish (fresh deploy, restart, or scale-up) typically reaches a **30–50% hit ratio within the first hour** of real traffic, then climbs more slowly to a steady-state **80–90% within 24–48 hours**. Two things keep that curve smooth and prevent thundering-herd behavior in steady state:

- Varnish misses don't usually mean re-processing — most fall through to OSC, which is much larger and holds items for far longer (default 90 days). So "cold Varnish" almost never means "cold system."
- The platform applies a small jitter to per-image TTLs so items that were cached together don't all expire at the same instant. This avoids the cyclical cache-slamming you'd otherwise see during catalog-wide refreshes.

**Important:** restarting a Varnish pod (chart upgrade, resource change, env-var change, anything that triggers a rollout) **empties its in-memory cache**. Multiple replicas are still fine because each pod has its own cache and Edge load-balances across them, so a rolling update only loses one pod's cache at a time. But **don't autoscale Varnish** — reactive scaling means the pods you add are cold exactly when you need warm capacity, and the pods you remove take warm cache with them. Pick a steady `varnish.replicaCount` sized for peak traffic.

**Important:** keep `edge.replicaCount` equal to `varnish.replicaCount`. The edge enforces concurrent-connection limits to protect Varnish from overload, and those limits are tuned assuming a 1:1 ratio. Skewing the ratio (more edges per Varnish, or more Varnishes per edge) either over-throttles legitimate traffic or lets too much through for Varnish to handle.

**Defaults:** 1 replica, 1 GiB / 500m CPU requests, 4 GiB memory limit, 10 GiB / 500 GiB ephemeral storage request/limit. Storage strategy via `varnish.env.VARNISH_STORAGE` and the per-tier knobs — see [CUSTOMIZATIONS.md](CUSTOMIZATIONS.md) and the inline comments in `values.yaml`.

### Backend

**What it does:** Request orchestrator. For each request the edge can't satisfy from Varnish, the backend decides what's needed: serve a processed variant from OSC, transform an existing origin image via the processor, fetch a fresh origin image via the fetcher, etc. It then dispatches to those components and **buffers the in-flight image bytes in memory** as they move between layers.

**How it scales:** **RAM-heavy** because it holds full image bodies in memory while orchestrating. Under-provisioning backend memory shows up as OOM-kills exactly when traffic spikes — the worst possible time. The defaults already set a generous 6 GiB limit; keep that headroom and only trim if you've measured.

The backend supports HPA on CPU, but in practice memory pressure shows up before CPU pressure on this component.

**Defaults:** 2 replicas, 1 GiB / 250m CPU requests, 6 GiB memory limit. HPA available (off by default).

### Fetcher

**What it does:** Pulls original images from customer origins — generic HTTP origins, S3, Wasabi, etc. — and streams them onward to the processor and the OSC. Only runs on cache-miss paths.

**How it scales:** **CPU- and bandwidth-bound during miss storms.** Scaling pattern is similar to the processor — give it generous CPU requests and turn on the HPA at non-PoC traffic levels. At high traffic, network bandwidth to your origins becomes a real constraint. Tunables of note: `IE_ORIGINFETCHER_FETCHER_THREADS_FOR_DOMAIN`, `IE_ORIGINFETCHER_MAX_QUEUE_PER_ORIGIN`, `IE_ORIGINFETCHER_FETCHER_CLIENT_DIAL_TIMEOUT`.

**Defaults:** 2 replicas, 768 MiB / 250m CPU requests, 4 GiB memory limit. HPA available (off by default; `maxReplicas: 4` if enabled).

### Processor

**What it does:** Image transformation, optimization and re-encoding. Resize, crop, format conversion (JPEG, WebP, AVIF, JP2, etc.), quality adjustment. Only runs on cache-miss paths — once a variant is processed and stored in OSC, repeat requests don't touch the processor.

**How it scales:** **CPU-bound during misses, and usually the first thing that saturates** when something is wrong (cold cache, big origin push, sudden new device class hitting the edge). Cache hits cost essentially nothing, but a wave of misses pegs processor CPU before any other component shows pressure. Give it generous CPU requests, and at any non-PoC traffic level turn on the HPA with a high `maxReplicas` so it can scale into a miss storm.

Useful tunables when CPU is plentiful but throughput is low: `IE_PROCESSOR_PROCESSINGTHREADS_PER_CORE` (default 1.2 — push toward 1.5 if you have headroom), and `IE_PROCESSOR_VIPS_DISC_THRESHOLD` (default 10 GiB; lower it to push large images through libvips' on-disk path instead of memory).

**Defaults:** 2 replicas, 1 GiB / 500m CPU requests, 6 GiB memory limit. HPA available (off by default; `maxReplicas: 16` if enabled).

### Object Storage Cache (OSC)

**What it does:** Persistent disk cache for everything: origin images/objects and their metadata **plus** every processed variant the platform has produced recently. The only stateful component in the chart — backed by a PVC. Cache hits here mean the backend can answer without touching fetcher or processor at all.

**How it scales:** Wants a **big, fast disk.** Sizing is driven by your catalog and how many variants you serve per origin, not by raw req/sec. Variants are typically **~10× smaller than the originals** they came from (smaller dimensions and stronger optimization), so a useful rough formula is:

```
OSC working set ≈ origin_catalog_size × (1 + variants_per_origin / 10)
```

For example, 1 million origin images at ~2 MB average plus ~20 variants per origin works out to about 2 TiB of originals plus ~4 TiB of variants — call it ~6 TiB total — and the same number holds whether you serve it at 10 req/sec or 1000 req/sec. Adjust the `/10` ratio if your real variant-to-origin size ratio is different (e.g. mostly thumbnail variants pull it closer to /20; a few large reformats pull it closer to /5).

OSC IO latency is on the hot path for every cache hit, so a slow storage class hurts everywhere — slow OSC shows up as backend memory pressure (because requests buffer longer) and processor queue growth (because the cache doesn't absorb load fast enough). Use the fastest SSD-class storage class your provider offers; cheap rotational disks will starve the rest of the pipeline.

CPU footprint is small. Memory footprint is moderate (caching metadata, in-flight reads).

**Eviction:** OSC has two complementary cleanup paths:

- A background **TTL expirer** that periodically scans the cache and removes anything whose TTL has elapsed. This runs continuously, regardless of disk pressure. Tune via `OSC_MAX_TTL` (default 90 days) and `OSC_EXPIRER_LOOP_DELAY` (default 5 m between scan passes).
- A **disk-pressure cleaner** that activates when free disk drops to or below `OSC_FS_DISK_FREE_LIMIT_PERC` (chart default 15%) and aggressively deletes items — even un-expired ones — until free disk climbs back up to `OSC_FS_DISK_FREE_TARGET_PERC` (chart default 20%). This is the safety net that keeps the volume from filling completely. Note: `TARGET` must be **higher** than `LIMIT` — they represent free-space thresholds, not used-space, so cleaning *raises* the percentage. If you misconfigure them with `TARGET <= LIMIT`, the application logs a warning and forcibly sets `TARGET = LIMIT + 2`.

`OSC_MAX_TTL` is the main lever you have:

- **Lower it** (e.g. 720h / 30 days) if your catalog is large and you want to bound disk usage at the cost of a lower hit ratio.
- **Raise it** (or leave at the default 90 days) if you have plenty of disk and want to maximize hit ratio.

If the disk-pressure cleaner is firing regularly in your metrics, you're undersized — give the PVC more room rather than relying on the cleaner as a steady-state mechanism.

**Important:** the OSC must run as **exactly one replica** in this chart. Running multiple OSC pods splits the cache: each pod stores a different subset of images, requests to the "wrong" pod are treated as misses and re-fetched from the origin, and your effective hit ratio collapses. Scale OSC by giving the single pod a bigger, faster PVC and more memory — not by adding replicas. **OSC sharding (multi-replica with consistent hashing) is on the ImageEngine Kube roadmap for 2026.**

**Defaults:** 1 replica, 2 GiB / 500m CPU requests, 4 GiB memory limit, 40 GiB PVC. Tunables: `objectStorageCache.persistence.size`, `objectStorageCache.persistence.storageClass`, `OSC_MAX_TTL` (default 90 days), `OSC_FS_DISK_FREE_LIMIT_PERC` / `OSC_FS_DISK_FREE_TARGET_PERC` (cleaner thresholds), `OSC_EXPIRER_LOOP_DELAY` (background scanner cadence).

### Rsyslog

**What it does:** Receives syslog (port 514) from every other component and aggregates it. By default the `forwarder` is `discard`, so logs are silently dropped — set `rsyslog.forwarder` to the IP/host of a downstream log collector to actually do something with them.

The chart also disables statsd emission on backend, fetcher, processor, and OSC by default (because rsyslog would just discard the metrics). To turn it back on, set `IE_BACKEND_STATSD_ENABLE` / `IE_ORIGINFETCHER_STATSD_ENABLE` / `IE_PROCESSOR_STATSD_ENABLE` / `OSC_STATSD_ENABLE` to `true` in the relevant component's `env:` block, and point `rsyslog.forwarder` at a real statsd-aware collector.

**How it scales:** It doesn't, really. Tiny aggregator with negligible per-request cost. You should never need to touch its sizing.

**Defaults:** 1 replica, 128 MiB / 100m CPU requests, 256 MiB memory limit.

## Tier 1 — Low traffic / PoC (<10 req/sec, 100/sec bursts)

Chart defaults are fine. This is the "evaluate ImageEngine on a free-tier cluster" footprint.

- 1× edge, 1× varnish, 2× backend, 2× fetcher, 2× processor, 1× OSC, 1× rsyslog.
- OSC PVC: **40 GiB** is enough for a smoke test. If you're actually proving out catalog freshness, jump to 100–200 GiB so you can see realistic 30-day retention behavior.
- Varnish: default `VARNISH_STORAGE: tiered` with 1 GiB request / 4 GiB limit RAM is plenty.
- Processor / fetcher: HPA off; defaults are fine.
- Backend: defaults (1 GiB request, 6 GiB limit) are plenty.
- Cluster footprint: a single small node group, ~8 vCPU / 16 GiB total across at least 3 nodes so that pods can spread out.

What this is **not** good for: validating production sizing decisions. Cache hit ratios at PoC traffic levels do not predict anything about cache hit ratios at production traffic levels.

## Tier 2 — Medium traffic (<200 req/sec, 750/sec bursts)

You're past PoC and serving real traffic. Most of the value here comes from giving Varnish more RAM and OSC more disk; per-component replica counts go up modestly.

- Edge and Varnish: **2 replicas each** (keep these matched 1:1 — see the Edge / Varnish sections above). Mostly for redundancy at this tier, not throughput.
- Varnish, additionally: **bump RAM hard** — request 4–8 GiB, limit 12–16 GiB. This is your single highest-leverage knob. If you have spare RAM, give it to Varnish.
- Backend: 3–4 replicas. Hold the memory limit at the default 6 GiB (or higher); do not trim it.
- Fetcher: 3–4 replicas with **HPA enabled** so a miss storm can scale you out automatically.
- Processor: 3–4 replicas with **HPA enabled** at `targetCPUUtilizationPercentage: 80`. The chart already ships `maxReplicas: 16` for the processor HPA — that ceiling is fine for this tier.
- OSC PVC: **500 GiB to 2 TiB** depending on your origin catalog size. Use a fast (NVMe-backed) storage class — your provider doc lists the right one.
- Cluster footprint: ~3–5 nodes of 8 vCPU / 16 GiB, or equivalent.

Turn on real metrics now (request rate per pod, Varnish hit ratio, OSC fill, processor CPU saturation). Tune from there.

## Tier 3 — High traffic (>200 req/sec, >750/sec bursts)

At this point you should be making sizing decisions from your own metrics, not from a generic doc. The starting points below assume a relatively miss-heavy workload (lots of unique URLs, new variants); a mostly cache-hit workload at the same req/sec needs much less.

- Edge and Varnish: **same count, 3+ each** (1:1 ratio — see the Edge / Varnish sections above). Pin edge to a node pool with spare CPU bursting headroom — no component in the chart has a CPU limit, so the kernel will let edge stretch into idle cores under spike load.
- Varnish, additionally: the largest RAM you can spare per pod (8–32 GiB+), `VARNISH_STORAGE: tiered` with the file-backed tiers sized for your medium/large image working set. Consider dedicating a node pool to Varnish so the file-backed tier doesn't compete with other pods for disk IO.
- Backend: 4+ replicas with HPA on; keep memory generous (6+ GiB limit) — this is the layer that buffers full images in flight.
- Fetcher: HPA on, `maxReplicas` raised (e.g. 16+). Bandwidth to your origins becomes a real constraint here.
- Processor: HPA on, `maxReplicas` 16+ (raise from default if you bench higher). Consider a dedicated CPU-optimized node pool via `nodeSelector` so a miss storm doesn't evict other workloads. Tune `IE_PROCESSOR_PROCESSINGTHREADS_PER_CORE` if you can keep cores busy without context-switch overhead.
- OSC PVC: **multi-TiB on the fastest storage class your provider offers**. OSC IO latency directly affects every cache hit. Slow OSC disk shows up as backend memory pressure (because everything buffers in backend longer) and processor queue growth.
- Cluster footprint: heterogeneous — small nodes for edge/varnish/backend, CPU-optimized nodes for processor/fetcher, and a node with a fast attached disk for OSC.

## Cross-cutting notes

- **Look at Varnish hit ratio before scaling anything downstream.** A small hit-ratio improvement is usually worth more than doubling a downstream component.
- `**replicaCount` is ignored** for components where `autoscaling.enabled: true` — the HPA owns it. Set `autoscaling.minReplicas` instead.
- **Bench at realistic traffic** before locking in sizing. PoC traffic levels do not predict production cache behavior at all.

## Next

- [CUSTOMIZATIONS.md](CUSTOMIZATIONS.md) — exactly which values to set for replicas, resources, autoscaling, Varnish storage, etc.
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — when sizing turns out to be wrong.

