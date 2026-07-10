# Deployment Topologies

ImageEngine is a request pipeline:

```
client → edge → varnish → backend → { origin fetcher | processor | object storage cache (OSC) }
         └────── frontend tier ─────┘  └──────────────── backend stack ────────────────┘
```

By default this chart deploys **the whole pipeline as one release** in one
cluster. That is the normal, recommended deployment — most installs run the full
pipeline behind their own CDN and never split it. If that's you, skip this
document; you don't need any of the settings below.

For deployments that need it, the chart can also split the pipeline into two
independently-deployable tiers, so you can run a **frontend-only** release and a
**backend-only** release from the same chart — for example regional frontend
points-of-presence pointing at one central backend stack.

Two toggles select the topology (both default `true`):

| Values | Renders | Use for |
|---|---|---|
| `frontend.enabled: true`, `backendStack.enabled: true` | Everything (default) | The normal single-cluster install |
| `frontend.enabled: true`, `backendStack.enabled: false` | edge + Varnish only | Regional frontend PoPs pointing at a remote backend |
| `frontend.enabled: false`, `backendStack.enabled: true` | backend + fetcher + processor + OSC only | The central backend stack that serves remote frontends |

At least one tier must be enabled — disabling both is rejected at install time.

`frontend.enabled` gates the edge Deployment, the Varnish StatefulSet, their
Services, the Varnish PodDisruptionBudget/PriorityClass, and the carbon.txt
ConfigMap. `backendStack.enabled` gates backend + fetcher + processor + OSC,
their Services, the component autoscalers, and the OSC PDB/PriorityClass.
Component-level tuning stays where it always was (`edge:`, `varnish:`,
`backend:`, `fetcher:`, `processor:`, `objectStorageCache:`).

## The multi-region split

```
 us-west     us-central     us-east
 ┌───────┐   ┌───────┐      ┌───────┐
 │ edge  │   │ edge  │      │ edge  │      frontend-only releases
 │varnish│   │varnish│      │varnish│      (frontend.enabled=true,
 └───┬───┘   └───┬───┘      └───┬───┘       backendStack.enabled=false)
     │           │              │
     └───────────┼──────────────┘
                 ▼
        ┌──────────────────┐
        │  backend LB       │   private / internal (us-east)
        │  (ClusterIP or    │
        │   internal LB)    │
        └────────┬──────────┘
                 ▼
        backend → { fetcher | processor | OSC }   backend-only release
                                                  (frontend.enabled=false,
                                                   backendStack.enabled=true)
```

Each regional frontend's Varnish sends cache misses to the backend LB;
`varnish.ieBackends` is the address it uses.

## Frontend-only install

```yaml
frontend:
  enabled: true
backendStack:
  enabled: false
varnish:
  # REQUIRED. The remote backend LB address(es). Accepts a hostname, an SRV
  # pool name, or IPs (comma-separated), resolved by ie-varnish-autoconfig.
  ieBackends: "ie-backend.us-east.internal.example.com"
identity:
  region: us-west
```

The chart refuses to render a frontend-only install without `varnish.ieBackends`
— there would be nothing for Varnish to talk to.

See [`examples/values-frontend-only.yaml`](../examples/values-frontend-only.yaml).

### How the backend address is used

`varnish.ieBackends` becomes the Varnish `IE_BACKENDS` value, consumed by
`ie-varnish-autoconfig`, which runs as a service inside the Varnish pod and
generates Varnish's backend VCL. Behavior worth knowing:

- **It re-resolves on a loop (~10s) and reloads Varnish when the resolved set
  changes.** A backend LB whose IPs change behind a *stable hostname* is picked
  up automatically, with no redeploy. Changing the hostname itself is a values
  change and rolls the pods.
- **The backend must listen on port 80** unless you encode an explicit port in
  `ieBackends`. The chart's `backend.service.port` defaults to 80 to match.
- **IPv4 only.** `ie-varnish-autoconfig` resolves IPv4 addresses; an IPv6-only
  backend endpoint is not supported (a dual-stack endpoint works over its IPv4
  address). This is not a limitation in practice for the common IPv4 clusters.
- **Health probing.** Varnish probes each resolved backend at
  `GET /api/v1/health` (expects `200`, plain HTTP). Behind an LB it probes the
  **LB endpoints**, not individual backend pods, so the LB must forward
  `/api/v1/health` to a healthy backend. If the whole backend is unreachable,
  the frontend fails **closed** and returns `503` — a down backend is a `503`,
  not a silent success. (In the ImageEngine architecture repo this is documented
  in `docs/operations/frontend-status-codes.md`.)
- **Multiple backend clusters** work too — `ieBackends` takes a comma-separated
  list, a DNS name resolving to several IPs, or an SRV record. Single-target is
  the simplest and the documented default.

## Backend-only install

```yaml
frontend:
  enabled: false
backendStack:
  enabled: true
backend:
  service:
    type: LoadBalancer
    # Make the LB PRIVATE. Example: AWS internal NLB.
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-scheme: internal
    # And/or restrict to the frontend clusters' egress ranges.
    loadBalancerSourceRanges:
      - 10.0.0.0/8
identity:
  region: us-east
```

See [`examples/values-backend-only.yaml`](../examples/values-backend-only.yaml).

### ⚠ Security: keep the backend LoadBalancer private

This is the one thing you must get right when exposing the backend:

- The backend's single listener (`:8000`) serves **both** the data plane **and
  unauthenticated admin endpoints** (`POST /api/v1/loglevel`,
  `POST /api/v1/originreturn`). Anyone who can reach the LB can toggle those.
- Open-source Varnish **cannot originate TLS** to a backend, so frontend →
  backend traffic is **plain HTTP**. TLS-terminating something in front of the
  backend does not help the remote Varnish tiers.

Therefore a backend `LoadBalancer` **must** be private — an internal LB reached
over VPC peering / VPN / private interconnect — or, at minimum, locked down with
`backend.service.loadBalancerSourceRanges` to your frontend clusters' egress
addresses. The chart prints a prominent warning at install time if you set
`type: LoadBalancer` with no source ranges, but it does **not** hard-block it
(a schema guard can't tell a private internal-LB annotation from a public one).
Never expose the backend to the open internet.

If you can keep both tiers on the same private network (e.g. same VPC,
different clusters), prefer `type: ClusterIP` reachability over a peered/VPN
private LB where your platform allows it.

**The same warning applies to an Ingress.** On a backend-only install
`ingress.enabled: true` points the Ingress at the backend Service (there is no
edge to target), so the Ingress fronts that same unauthenticated, plain-HTTP
listener. Worse, the chart's provider presets are edge-oriented: with
`provider: aws`, for example, the generated Ingress inherits
`alb.ingress.kubernetes.io/scheme: internet-facing`, which would publish the
backend to the internet. A backend-only Ingress is rarely useful anyway (Varnish
can't use TLS termination), so **prefer a private `backend.service` LoadBalancer
over an Ingress** for backend exposure. If you must use an Ingress, force it
internal/private (e.g. override the scheme annotation and/or restrict source
ranges at the controller) — the chart warns at install time when a backend-only
Ingress is enabled, but does not rewrite your annotations for you.

## What does *not* change across regions

Purge/ban and live-config propagation are **emitter-based and
topology-independent**. Every frontend (in any region) subscribes to the
`frontend/settings` and `frontend/purge` channels; OSC subscribes to
`origin-cache/purge`; the backend subscribes to `origin-conf/changes` — all over
the shared emitter broker (`imageengine.emitterServer`). A purge issued from the
control plane reaches every regional frontend automatically. Splitting the
pipeline requires **no** invalidation rewiring.

## Running both tiers in one cluster (two releases)

You can install a frontend-only release and a backend-only release into the same
cluster and wire them together by Service DNS. This is a good way to smoke-test
the split before going multi-region, and it lets you upgrade the cache tier and
the processing tier on independent cadences.

```bash
# Backend stack
helm install ie-backend imageengine/imageengine-kube -n ie \
  --set frontend.enabled=false

# Frontend tier, pointed at the backend release's in-cluster Service
helm install ie-frontend imageengine/imageengine-kube -n ie \
  --set backendStack.enabled=false \
  --set varnish.ieBackends=ie-backend-imageengine-kube-backend.ie.svc.cluster.local
```

(`<release>-imageengine-kube-backend` is the backend Service name; adjust for
your release name and namespace.)

## Smoke testing

The [GETTING_STARTED](GETTING_STARTED.md) smoke test drives the pipeline through
the **edge**, so it applies to any install that has a frontend. A backend-only
install has no edge — smoke-test it from a frontend tier that points at it, or
directly:

```bash
kubectl -n ie port-forward svc/<release>-imageengine-kube-backend 8000:80
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/api/v1/health
```

## Reference

- ADR 0021 (architecture repo) — the decision and rationale behind split
  topology.
- [CUSTOMIZATIONS.md](CUSTOMIZATIONS.md) — everything else you can tune.
