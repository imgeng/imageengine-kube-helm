# Monitoring

Every ImageEngine Kube component exposes Prometheus metrics. This guide covers how to scrape them, which ones to watch, and a starting set of dashboard panels and alerts. The metric reference at the end lists everything each component exports.

This guide matches chart 1.10.1 and the images it pins (edge 4.12.0, Varnish 9.1.0-2, backend 2.16.0, fetcher 1.32.0, processor 3.30.0, OSC 3.7.0). Metric names can change between image versions; `curl` a pod's `/metrics` (below) to see exactly what your version exports.

## Where the metrics are

Each pod serves Prometheus text format at `/metrics` on port **9464**, a container port named `metrics`. It is separate from the port that serves images, and it is **not** on the edge LoadBalancer or any other chart Service, so nothing outside the cluster can reach it. Scrape the pods directly.

To look at one pod's metrics by hand:

```bash
kubectl port-forward -n imageengine deploy/imageengine-kube-edge 9464:9464 &
curl -s localhost:9464/metrics | grep '^imageengine_'
```

Use `pod/imageengine-kube-varnish-0`, `deploy/imageengine-kube-backend`, `deploy/imageengine-kube-fetcher`, `deploy/imageengine-kube-processor` or `pod/imageengine-kube-osc-0` for the other components (prefix the names with your release name if it isn't `imageengine-kube`).

Every pod carries the labels `app: imageengine-kube` and `tier`, where `tier` is one of `edge`, `varnish`, `backend`, `fetcher`, `processor` or `object-storage`.

## Scraping

### With the Prometheus Operator (kube-prometheus-stack)

The chart can create a `PodMonitor` that scrapes every component on its `metrics` port. It needs the Prometheus Operator CRDs (`monitoring.coreos.com/v1`) in the cluster.

```yaml
metrics:
  podMonitor:
    enabled: true
    interval: 30s
    scrapeTimeout: 10s
    labels:
      release: kube-prometheus-stack   # match your Prometheus's podMonitorSelector
```

By default kube-prometheus-stack only picks up PodMonitors labelled with its own Helm release name (`release: <name>`). Either set that label under `labels`, or install kube-prometheus-stack with `prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false` so it selects every PodMonitor.

The PodMonitor is created in the release namespace and selects pods in that namespace only. It copies the pod's `tier` label onto every series, so `tier` is available in queries alongside the `namespace` and `pod` labels Prometheus adds.

Check that it works in the Prometheus UI under **Status → Targets**: there should be one target per ImageEngine pod, all `UP`.

### With scrape annotations

If your Prometheus discovers pods through `prometheus.io/*` annotations (the `kubernetes-pods` job in the community `prometheus` chart does), leave the PodMonitor off and annotate each component's pods:

```yaml
x-metrics-annotations: &metricsAnnotations
  prometheus.io/scrape: "true"
  prometheus.io/port: "9464"
  prometheus.io/path: /metrics

edge:
  podAnnotations: *metricsAnnotations
varnish:
  podAnnotations: *metricsAnnotations
backend:
  podAnnotations: *metricsAnnotations
fetcher:
  podAnnotations: *metricsAnnotations
processor:
  podAnnotations: *metricsAnnotations
objectStorageCache:
  podAnnotations: *metricsAnnotations
```

These annotations are a convention, not a Kubernetes feature: they do nothing unless your scrape config reads them. Keep the `tier` pod label when relabelling (`__meta_kubernetes_pod_label_tier`) so the queries below work.

### With other agents

Grafana Alloy, the OpenTelemetry Collector's Prometheus receiver, Datadog's OpenMetrics check and similar agents all work the same way: discover pods with the label `app=imageengine-kube`, scrape port 9464 at `/metrics`, and keep the `tier` pod label.

### NetworkPolicies

If you turn on `edge.warmStart.networkPolicy.enabled`, only the release's own edges can reach the edge admin port (9464) unless you allow your scraper too. Add its namespace to `metricsFrom`:

```yaml
edge:
  warmStart:
    networkPolicy:
      enabled: true
      metricsFrom:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
```

Apply the same allowance to any NetworkPolicies of your own that cover the other components.

## What to watch

The queries below are PromQL and assume the series carry `namespace`, `pod` and `tier` labels. Add `{namespace="..."}` selectors if you run more than one release.

### Traffic, errors and cache hit ratio (edge)

The edge sees every client request, so start here. `imageengine_edge_responses_total` counts responses by status `code`, Varnish `cache` result and the `image_source` layer that served the image:

| `image_source` | Served from |
|---|---|
| `frontend` | Varnish (a cache hit) |
| `processed-cached` | The Object Storage Cache (OSC), which already had this variant |
| `origin-cached` | The OSC's copy of the original image, resized by the processor |
| `external` | Your origin, fetched and resized by the processor |
| `other` | Varnish answered without a known source (usually an error) |
| `none` | The edge answered itself without asking Varnish (for example a rejected request) |

| What | Query |
|---|---|
| Requests per second | `sum(rate(imageengine_edge_responses_total[5m]))` |
| Varnish hit ratio | `sum(rate(imageengine_edge_responses_total{cache="hit"}[5m])) / sum(rate(imageengine_edge_responses_total{cache!="none"}[5m]))` |
| Where requests are served from | `sum by (image_source) (rate(imageengine_edge_responses_total[5m]))` |
| 5xx ratio | `sum(rate(imageengine_edge_responses_total{code=~"5.."}[5m])) / sum(rate(imageengine_edge_responses_total[5m]))` |
| 502s caused by your origins, versus ImageEngine | `sum by (reason) (rate(imageengine_edge_upstream_502_total[5m]))` |
| p95 response time by source | `histogram_quantile(0.95, sum by (le, image_source) (rate(imageengine_edge_response_duration_seconds_bucket[5m])))` |

A hit ratio that drops after a deploy or a Varnish restart and recovers over the following hours is the cache warming up. A hit ratio that stays low while Varnish evicts objects (next section) means the cache is too small for your traffic.

`imageengine_edge_upstream_502_total{reason="customer_origin"}` counts requests where your origin failed; a 502 is only returned for those. ImageEngine's own failures are answered as 503 or 504 and counted with `reason="imageengine_failure"`.

`imageengine_edge_internal_duration_seconds` is the response time minus the time the backend spent fetching from your origin or the OSC. Use it to tell slow origins apart from slow processing.

### Edge saturation

| What | Query |
|---|---|
| In-flight requests against the admission limit | `max by (pod) (imageengine_edge_inflight_requests / imageengine_edge_concurrency_limit)` |
| Rejected requests | `sum by (reason, status) (rate(imageengine_edge_reject_total[5m]))` |
| Errors talking to Varnish | `sum by (type) (rate(imageengine_edge_proxy_errors_total[5m]))` |
| Requests per Varnish shard | `sum by (ordinal) (rate(imageengine_edge_varnish_shard_selected_total[5m]))` |

`proxy_errors_total` types are `upstream` (Varnish connection failed, 503), `timeout` (504), `no_shards` (503) and `client_closed` (the client went away first, 499). `client_closed` at a low rate is normal.

### Varnish

Each Varnish shard exports its `varnishstat` counters. [SIZING.md](SIZING.md#varnish) explains how these relate to shard sizing.

| What | Query | Look for |
|---|---|---|
| Shard is up | `imageengine_varnish_up` | 0 means `varnishd` is down |
| Cache restarts | `increase(imageengine_varnish_mgt_child_died_total[1h])` | Any increase; a restart empties the in-memory tier |
| Hit ratio per shard | `rate(imageengine_varnish_main_cache_hit_total[5m]) / (rate(imageengine_varnish_main_cache_hit_total[5m]) + rate(imageengine_varnish_main_cache_miss_total[5m]))` | Uneven shards |
| Evictions | `rate(imageengine_varnish_main_n_lru_nuked_total[5m])` | Sustained evictions with a low hit ratio: the cache is too small |
| Storage tier full | `sum by (pod, tier) (rate(imageengine_varnish_storage_c_fail_total[5m]))` | Allocations failing because a tier is full |
| Storage tier fill | `imageengine_varnish_storage_g_bytes / (imageengine_varnish_storage_g_bytes + imageengine_varnish_storage_g_space)` | Close to 1 |
| Requests waiting for a worker thread | `imageengine_varnish_main_thread_queue_len` | Above 0 for more than a few minutes |
| Work refused | `rate(imageengine_varnish_main_sess_dropped_total[5m]) + rate(imageengine_varnish_main_req_dropped_total[5m])` | Any nonzero rate |
| Memory against the limit | `max by (pod) (imageengine_varnish_cgroup_memory_anon_bytes) / max by (pod) (imageengine_varnish_memory_limit_bytes)` | Approaching 1 risks an out-of-memory kill |
| Backends failing health checks | `imageengine_varnish_backend_healthy == 0` | Any backend, including standby ones |

Health-check requests show up as a steady trickle of synthetic responses and session closes; those aren't errors.

### Backend pipeline

The backend, fetcher, processor and OSC each export the same request metrics, labelled with `component`, `method`, `route` and `code`:

| What | Query |
|---|---|
| Request rate per component | `sum by (component) (rate(imageengine_http_requests_total[5m]))` |
| 5xx rate per component | `sum by (component) (rate(imageengine_http_requests_total{code=~"5.."}[5m]))` |
| p95 latency per component | `histogram_quantile(0.95, sum by (le, component) (rate(imageengine_http_request_duration_seconds_bucket[5m])))` |

And their own saturation signals:

| What | Query | Look for |
|---|---|---|
| OSC hit ratio (backend) | `sum(rate(imageengine_backend_cache_lookups_total{result=~"processed_hit\|origin_hit"}[5m])) / sum(rate(imageengine_backend_cache_lookups_total[5m]))` | How often a Varnish miss avoids your origin |
| Origin fetch outcomes | `sum by (result) (rate(imageengine_fetcher_fetch_results_total[5m]))` | `timeout`, `network_error`, `origin_5xx` point at your origin |
| Fetcher queue | `max(imageengine_fetcher_queue_depth)` and `rate(imageengine_fetcher_queue_full_total[5m])` | Queue-full rejections |
| Origin fetch p95 | `histogram_quantile(0.95, sum by (le) (rate(imageengine_fetcher_fetch_duration_seconds_bucket[5m])))` | Slow origins |
| Processor queue | `max(imageengine_processor_queue_utilization_ratio)` | Sustained values near 1 |
| Processor rejections | `rate(imageengine_processor_queue_full_total[5m])` | Any nonzero rate |
| Processing p95 | `histogram_quantile(0.95, sum by (le) (rate(imageengine_processor_processing_duration_seconds_bucket[5m])))` | Rising with steady traffic |
| OSC disk free | `min by (pod) (imageengine_osc_disk_free_ratio)` | Below 0.1 |

A rising processor queue with steady traffic means the processor needs more CPU or replicas; see [CUSTOMIZATIONS.md](CUSTOMIZATIONS.md#how-do-i-scale-a-component).

### Edge Warm Start

With `edge.warmStart.enabled`, each edge reports how its start-up copy went and how far it lags its peers:

| What | Query |
|---|---|
| Start-up results | `sum by (result) (increase(imageengine_edge_kvcache_bootstrap_total[1h]))` |
| Lag behind peers | `max(imageengine_edge_kvcache_sync_lag_seconds)` |
| Sync errors | `sum by (reason) (rate(imageengine_edge_kvcache_sync_errors_total[5m]))` |

[TROUBLESHOOTING.md](TROUBLESHOOTING.md) explains what each start-up result means.

## Example dashboard

A Grafana dashboard with these rows covers most day-to-day questions. Use a `namespace` variable if you run several releases.

1. **Overview:** requests per second, Varnish hit ratio, 5xx ratio, p95 response time (edge).
2. **Where requests are served from:** stacked rate by `image_source`, and p95 response time by `image_source`.
3. **Errors:** 5xx by `code`; 502s by `reason`; edge proxy errors by `type`; edge rejections by `reason`.
4. **Varnish:** hit ratio per shard, evictions, storage tier fill, thread queue length, memory against the limit, `up`.
5. **Backend pipeline:** request rate and p95 latency per component, OSC hit ratio, fetch outcomes, fetcher and processor queues.
6. **Capacity:** CPU and memory per `tier` from your cluster's container metrics (`container_cpu_usage_seconds_total`, `container_memory_working_set_bytes`), OSC disk free.

## Example alerts

Starting points; tune the thresholds and durations to your traffic.

| Alert | Expression | For |
|---|---|---|
| Varnish shard down | `imageengine_varnish_up == 0` | 2m |
| Varnish refusing work | `rate(imageengine_varnish_main_sess_dropped_total[5m]) + rate(imageengine_varnish_main_req_dropped_total[5m]) > 0` | 5m |
| Varnish restarted | `increase(imageengine_varnish_mgt_child_died_total[10m]) > 0` | 0m |
| High 5xx ratio | `sum(rate(imageengine_edge_responses_total{code=~"5.."}[5m])) / sum(rate(imageengine_edge_responses_total[5m])) > 0.02` | 10m |
| Edge near its admission limit | `max(imageengine_edge_inflight_requests / imageengine_edge_concurrency_limit) > 0.8` | 10m |
| Processor queue full | `rate(imageengine_processor_queue_full_total[5m]) > 0` | 5m |
| OSC disk filling | `min(imageengine_osc_disk_free_ratio) < 0.1` | 15m |
| Target missing | `up{namespace="imageengine"} == 0` | 5m |

## Metric reference

All metrics are prefixed `imageengine_`. Counters end in `_total`; durations are in seconds and sizes in bytes. Labels have a small, fixed set of values: no URLs, hostnames or customer identifiers. Every component also exports the standard Go runtime and process metrics (`go_*`, `process_*`).

Some counters only appear after their first event (for example `imageengine_edge_reject_total` or `imageengine_backend_fetch_errors_total`), so they may be missing from an idle pod.

### Shared request metrics (backend, fetcher, processor, OSC)

| Metric | Type | Labels |
|---|---|---|
| `http_requests_total` | counter | `component`, `method`, `route`, `code` |
| `http_request_duration_seconds` | histogram | `component`, `method`, `route`, `code` |
| `http_requests_in_flight` | gauge | `component` |

`route` is the route template (for example `/api/v1/object`), not the requested URL. The edge reports requests with its own metrics instead.

### Edge

| Metric | Type | Labels | Description |
|---|---|---|---|
| `edge_requests_total` | counter | `method` | Requests received |
| `edge_responses_total` | counter | `code`, `cache`, `image_source` | Responses sent, by status, Varnish result and serving layer |
| `edge_response_duration_seconds` | histogram | `image_source`, `status_group` | End-to-end response time |
| `edge_internal_duration_seconds` | histogram | `image_source`, `status_group` | Response time minus the backend's origin/OSC fetch time |
| `edge_proxy_duration_seconds` | histogram | `class` | Time spent waiting on Varnish |
| `edge_proxy_errors_total` | counter | `type` | Errors talking to Varnish: `upstream`, `timeout`, `no_shards`, `client_closed` |
| `edge_upstream_502_total` | counter | `to`, `reason` | 502s from behind the edge: `customer_origin` or `imageengine_failure` |
| `edge_admit_total` | counter | `class` | Requests admitted |
| `edge_reject_total` | counter | `class`, `reason`, `status` | Requests rejected by admission control |
| `edge_inflight_requests` | gauge | | Admitted requests in flight |
| `edge_inflight_protected_requests` | gauge | | In-flight requests using reserved capacity |
| `edge_concurrency_limit` | gauge | | Configured admission limit |
| `edge_clients_tracked` | gauge | | Approximate number of tracked clients |
| `edge_client_ip_resolutions_total` | counter | `result` | How the client IP was chosen (see [TROUBLESHOOTING.md](TROUBLESHOOTING.md)) |
| `edge_varnish_shard_selected_total` | counter | `ordinal` | Requests routed to each Varnish shard |
| `edge_varnish_shard_reroute_total` | counter | `ordinal` | Requests rerouted after a connection failure on that shard |
| `edge_wurfl_lookup_duration_seconds` | histogram | | Device detection time |
| `edge_access_log_dropped_total` | counter | | Access log entries dropped under backpressure |
| `edge_kvcache_*` | | | Natural-width cache and Edge Warm Start: `entries`, `capacity`, `lookups_total`, `evictions_total`, `bootstrap_total`, `sync_lag_seconds`, `sync_errors_total` and others |

### Varnish

Exported from `varnishstat` by an exporter inside the Varnish container.

| Metric | Type | Labels | Description |
|---|---|---|---|
| `varnish_up` | gauge | | 1 when Varnish is readable, 0 while `varnishd` is down |
| `varnish_main_<counter>` | counter or gauge | | `MAIN.*` counters: `cache_hit`, `cache_miss`, `n_object`, `n_expired`, `n_lru_nuked`, `threads`, `threads_limited`, `thread_queue_len`, `sess_dropped`, `req_dropped`, `busy_sleep`, `busy_killed`, `backend_fail`, `fetch_failed` and others |
| `varnish_mgt_<counter>_total` | counter | | `child_start`, `child_died`, `child_panic` |
| `varnish_storage_<field>` | counter or gauge | `tier`, `type` | Per storage tier (`tier1`, `tier2`, `tier3`, `Transient`): `c_req`, `c_fail`, `c_bytes`, `c_freed`, `g_bytes`, `g_space` |
| `varnish_backend_<field>` | counter or gauge | `backend`, `ip`, `port`, `priority` | Per ImageEngine backend: `conn`, `req`, `fail`, `busy`, `unhealthy` |
| `varnish_backend_healthy` | gauge | `backend`, `ip`, `port`, `priority` | Latest health check, 1 or 0 |
| `varnish_cgroup_memory_{anon,file,current}_bytes` | gauge | | Container memory: non-reclaimable, page cache, total |
| `varnish_memory_limit_bytes` | gauge | `source` | Memory limit Varnish sized itself against |
| `varnish_cpu_{request,limit}_cores` | gauge | `source` | CPU request and limit |
| `varnish_param` | gauge | `name`, `units` | Effective thread pool and workspace parameters |

### Backend

| Metric | Type | Labels | Description |
|---|---|---|---|
| `backend_cache_lookups_total` | counter | `result` | OSC lookups: `processed_hit`, `origin_hit`, `miss` |
| `backend_cache_fetch_duration_seconds` | histogram | `cache` | OSC read time (`origin` or `processed`) |
| `backend_origin_fetch_duration_seconds` | histogram | | Round trip to the fetcher |
| `backend_processing_duration_seconds` | histogram | | Round trip to the processor |
| `backend_imgproc_results_total` | counter | `result` | Processor call outcomes: `ok`, `timeout`, `queue_full`, `client_queue_full`, `err` |
| `backend_fetch_errors_total` | counter | `reason` | Fetcher call errors: `timeout`, `other` |
| `backend_parse_errors_total` | counter | `reason` | Requests with invalid URLs or directives |
| `backend_{imgproc,osc,fetcher}_client_queue_depth` | gauge | | Outgoing queue depth to each service |

### Fetcher

| Metric | Type | Labels | Description |
|---|---|---|---|
| `fetcher_fetch_results_total` | counter | `result` | Every fetch outcome: `ok`, `timeout`, `network_error`, `origin_4xx`, `origin_5xx`, `origin_dns_error`, `origin_queue_full` and others |
| `fetcher_fetch_duration_seconds` | histogram | | Origin round-trip time |
| `fetcher_queue_depth` | gauge | | Fetches queued across all origins |
| `fetcher_queue_depth_max` | gauge | | Deepest single-origin queue |
| `fetcher_queue_full_total` | counter | | Fetches rejected because an origin's queue was full |
| `fetcher_inflight_fetches` | gauge | | Fetches running |
| `fetcher_active_origins` | gauge | | Origins with an active queue |
| `fetcher_dedup_hits_total` | counter | | Requests that joined a fetch already in flight |
| `fetcher_no_store_total` | counter | `kind` | Origin responses marked `Cache-Control: no-store` |
| `fetcher_origin_inspect_duration_seconds` | histogram | | Time spent reading image format and metadata |
| `fetcher_osc_put_queue_depth` | gauge | | Writes queued to the OSC |
| `fetcher_fetch_log_dropped_total` | counter | | Fetch log records dropped under backpressure |

### Processor

| Metric | Type | Labels | Description |
|---|---|---|---|
| `processor_images_total` | counter | `result` | Images processed: `success`, `error`, `fallback` |
| `processor_processing_duration_seconds` | histogram | | Time to process one image |
| `processor_time_in_queue_seconds` | histogram | | Time waiting before processing started |
| `processor_queue_depth` | gauge | | Images waiting |
| `processor_queue_capacity` | gauge | | Queue size |
| `processor_queue_utilization_ratio` | gauge | | `queue_depth / queue_capacity` |
| `processor_queue_full_total` | counter | | Images rejected because the queue was full |
| `processor_workers_active` | gauge | | Workers processing an image |
| `processor_tool_runs_total` | counter | `action`, `tool`, `success` | Image tool invocations |
| `processor_null_processed_total` | counter | `reason` | Images passed through unchanged |
| `processor_osc_put_queue_depth` | gauge | | Writes queued to the OSC |

### Object Storage Cache (OSC)

Each OSC shard reports its own disk and object metrics.

| Metric | Type | Labels | Description |
|---|---|---|---|
| `osc_storage_operations_total` | counter | `op`, `result` | Storage operations (`get`, `put`, `delete`) by outcome (`success`, `not_found`, `expired`, `error`) |
| `osc_storage_io_duration_seconds` | histogram | `op`, `type` | Disk read and write time |
| `osc_disk_free_ratio` | gauge | | Free space on the storage volume, 0 to 1 |
| `osc_object_ttl_seconds` | histogram | | TTL assigned to stored objects |
| `osc_ban_rules` | gauge | | Active purge rules |
| `osc_ban_operations_total` | counter | `op` | Purge rule operations |
| `osc_responses_total` | counter | `code`, `reason` | 410 responses for purged (`banned`) or `expired` objects |
| `osc_cache_invalidations_total` | counter | `event` | Objects invalidated when read |
