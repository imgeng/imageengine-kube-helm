# Troubleshooting

Common failure modes, what they look like, and how to fix them. Symptom-driven — find the section that matches what you're seeing, then run the diagnostic and apply the fix.

The examples below assume you followed [GETTING_STARTED.md](GETTING_STARTED.md) and installed into the `imageengine` namespace with release name `imageengine-kube` (so resources are named `imageengine-kube-*`). If you used different names, adjust `-n imageengine` and the resource names accordingly.

If you're stuck, the [commands cheatsheet](#commands-cheatsheet) at the bottom covers the kubectl/helm one-liners you'll use most.

---

## LoadBalancer service stays `<pending>`

**Symptom:**

```
$ kubectl get svc -n imageengine -l 'app=imageengine-kube,tier=edge'
NAME                                TYPE           EXTERNAL-IP    ...
imageengine-kube-edge   LoadBalancer   <pending>      ...
```

By default the chart creates the edge as a `Service type: LoadBalancer`. If nothing in the cluster knows how to satisfy that, the service sits in `<pending>` forever.

**Diagnose:**

```bash
kubectl describe svc -n imageengine imageengine-kube-edge
```

Look at the events at the bottom.

**Fix:** pick the option that matches your environment.

- **Managed cloud (EKS / GKE / AKS / DOKS / LKE):** the cloud's LB controller should be running by default. Check that you didn't accidentally set IAM/RBAC restrictions that block it. Confirm `provider:` is set in your values file so the right preset is applied.
- **Self-managed / bare metal:** install MetalLB (or front the cluster with an external LB). See [providers/CUSTOM.md](providers/CUSTOM.md).
- **Don't want a LoadBalancer at all:** set `service.type: ClusterIP` (and pair it with `ingress.enabled: true` if you want external access via your own ingress controller). See [How do I configure the edge Service?](CUSTOMIZATIONS.md#how-do-i-configure-the-edge-service) in the customizations doc.

---

## Every pod stuck in `ImagePullBackOff` / `ErrImagePull`

**Symptom:**

```
$ kubectl get pods -n imageengine
NAME                                          READY   STATUS             ...
imageengine-kube-edge-...         0/1     ImagePullBackOff   ...
imageengine-kube-backend-...      0/1     ErrImagePull       ...
```

**Diagnose:**

```bash
kubectl describe pod -n imageengine <one of the failing pods>
```

Look for messages like `pull access denied` or `unauthorized`.

**Fix:**

Confirm the image-pull secret exists in the install namespace:

```bash
kubectl get secret ie-kube-image-pull -n imageengine
```

If missing, create it (see [GETTING_STARTED.md](GETTING_STARTED.md) step 2). If present but pull is still failing, the credentials are wrong — recreate it with the correct ImageEngine API key as the password:

```bash
kubectl delete secret ie-kube-image-pull -n imageengine
kubectl create secret docker-registry ie-kube-image-pull -n imageengine \
  --docker-server=https://docker.scientiamobile.com/v2/ \
  --docker-username=<your-email> \
  --docker-password=<your-api-key> \
  --docker-email=<your-email>
```

If you renamed the secret via `secrets.imagePullSecretName`, the secret name in the namespace must match.

---

## Edge or backend in `CrashLoopBackOff` mentioning auth / API key

**Symptom:** Pod restarts repeatedly. `kubectl logs` shows messages about authentication failures, missing API key, or "subscription not active."

**Fix:**

1. Confirm the API key secret exists and has a `KEY` field:
  ```bash
   kubectl get secret ie-kube-api-key -n imageengine -o jsonpath='{.data.KEY}' | base64 -d
  ```
2. Confirm the value matches the API key from your ImageEngine Control Panel.
3. Confirm your ImageEngine Kube subscription or trial is active in the Control Panel — if not, the API rejects the key even if it's syntactically valid.

If the secret is wrong, recreate it:

```bash
kubectl delete secret ie-kube-api-key -n imageengine
kubectl create secret generic ie-kube-api-key -n imageengine --from-literal=KEY=<your-api-key>
kubectl rollout restart deploy -n imageengine -l app=imageengine-kube
```

---

## OSC PVC stuck in `Pending`

**Symptom:**

```
$ kubectl get pvc -n imageengine
NAME                                STATUS    ...   STORAGECLASS       ...
imageengine-kube-osc-pvc  Pending   ...   <unset>            ...
```

**Diagnose:**

```bash
kubectl describe pvc -n imageengine imageengine-kube-osc-pvc
```

Common causes:

- No StorageClass exists with the requested name (or no default StorageClass is marked).
- The provisioner for that StorageClass isn't running.
- No worker node has enough free space for the requested PVC size.

**Fix:**

- If you set `provider:`, the right preset class is picked automatically — make sure the cluster actually has that StorageClass:
  ```bash
  kubectl get storageclass
  ```
  On **EKS** this is the usual culprit: `provider: aws` requests `gp3`, but EKS doesn't create a `gp3` StorageClass by default (you typically only get a legacy `gp2`). Create one — see [providers/AWS.md → Storage](providers/AWS.md#storage) for the exact manifest (the provisioner differs between Auto Mode and standard EKS) — or override to the class you already have.
- Otherwise set it explicitly:
  ```yaml
  objectStorageCache:
    persistence:
      storageClass: "my-csi-class"
      size: "100Gi"
  ```
- If you're on bare metal with no CSI yet, install one (local-path-provisioner is the simplest — see [providers/CUSTOM.md](providers/CUSTOM.md)).

---

## 502 Bad Gateway from the edge

**Symptom:** `curl` against the edge returns 502.

**Diagnose:**

```bash
kubectl get pods -n imageengine -l app=imageengine-kube
kubectl logs -n imageengine deploy/imageengine-kube-edge --tail=50
kubectl logs -n imageengine deploy/imageengine-kube-varnish --tail=50
kubectl logs -n imageengine deploy/imageengine-kube-backend --tail=50
```

The edge sits in front of varnish, which sits in front of backend. A 502 means one of the downstream services is not Ready or is returning errors.

**Fix:**

- If varnish or backend pods are not `Ready`, check their logs and `kubectl describe`. Most often this is a configuration error in your values file.
- If they're Ready but logs show errors, the failure is downstream — fetcher origin reachability, processor crashing on a bad image, etc.

---

## 504 Gateway Timeout / very slow first request

**Symptom:** First request for a given URL takes 2+ seconds and sometimes times out. Subsequent requests for the same URL are fast.

This is a cache miss path — fetcher pulls the original from your origin, processor transforms it, OSC writes it to disk, then the response comes back through varnish and edge. If your origin is slow or unreachable, the whole chain stalls.

**Diagnose:**

```bash
kubectl logs -n imageengine deploy/imageengine-kube-fetcher --tail=100
```

Look for connection errors, timeouts, or DNS resolution failures pointing at your origin.

**Fix:**

- Confirm origin reachability from inside the cluster:
  ```bash
  kubectl run -it --rm dnsutils -n imageengine --image=busybox --restart=Never -- \
    wget -O- http://your-origin.example.com/path/to/image.jpg
  ```
- If your origin is fine but timeouts happen under load, raise:
  ```yaml
  fetcher:
    env:
      IE_ORIGINFETCHER_FETCHER_CLIENT_DIAL_TIMEOUT: "30s"
  ```
- For genuinely slow origins, scale the fetcher (`replicaCount` or `autoscaling`).

---

## Processor latency rising even with HPA enabled

**Symptom:** Processor pods are at maxReplicas, CPU is pinned at 100%, response latency keeps growing.

**Fix:**

The HPA can only add pods up to `maxReplicas`. Either raise it:

```yaml
processor:
  autoscaling:
    enabled: true
    minReplicas: 4
    maxReplicas: 32         # was 16
    targetCPUUtilizationPercentage: 80
```

…or give each pod more CPU headroom:

```yaml
processor:
  resources:
    requests:
      cpu: "2"
    limits:
      cpu: "4"
```

If you have spare CPU per pod but throughput is still low, raise the per-core thread count:

```yaml
processor:
  env:
    IE_PROCESSOR_PROCESSINGTHREADS_PER_CORE: "1.5"
```

See [SIZING.md](SIZING.md) for why processor saturation is the most common bottleneck.

---

## Image processing fails on very large origin images

**Symptom:** Specific large originals (50+ MP photos, multi-page TIFFs, etc.) return errors or 5xx responses while smaller images on the same origin work fine.

**Fix:**

libvips streams large images to disk to avoid blowing through pod memory. The threshold defaults to 10 GiB; lower it to push more images through the disk path:

```yaml
processor:
  env:
    IE_PROCESSOR_VIPS_DISC_THRESHOLD: "5g"
```

Also confirm the processor pod has enough ephemeral storage in its `resources.limits`.

---

## Ingress returns 404 even though the service is up

**Symptom:** `curl` directly against the LoadBalancer external IP works. `curl` against your hostname returns 404.

**Diagnose:**

```bash
kubectl get ingress -n imageengine
kubectl describe ingress -n imageengine imageengine-kube-ingress
```

**Fix:**

Two things to check:

1. **The hostname must match.** The chart creates a rule per host listed in `ingress.hosts`. A request with a `Host:` header that's not in that list will hit the ingress controller's default backend and 404.
2. `**ingress.className` must match what's actually installed.** If your cluster has `nginx` but `ingress.className: gce` was rendered (e.g. you set `provider: gke` but installed nginx), the GCE controller is the one that's supposed to handle the Ingress and it's not there.

Fix:

```yaml
ingress:
  enabled: true
  className: nginx                # match the controller you actually installed
  hosts:
    - images.example.com          # must match the Host header on incoming requests
```

---

## Ingress never gets an ADDRESS

**Symptom:** `kubectl get ingress` shows your Ingress but the `ADDRESS` column stays empty, and nothing routes to it. `kubectl describe ingress <name>` shows an event like `ingressClass 'nginx' not found` (or no events at all).

**Cause:** No controller is watching that ingress class. The class is set, but the controller that's supposed to reconcile it isn't installed. The most common case is **EKS Auto Mode**, which ships the **ALB** controller (`alb`) but **not** `ingress-nginx` — so a `className: nginx` Ingress just sits there orphaned.

**Diagnose:**

```bash
kubectl get ingressclass                          # which classes/controllers actually exist (cluster-scoped)
kubectl describe ingress -n imageengine imageengine-kube-ingress
```

**Fix:** make `ingress.className` match a class that exists. On EKS (`provider: aws`) the preset already defaults to `alb`; if you previously pinned `nginx`, either remove that override or install `ingress-nginx`. See [providers/AWS.md](providers/AWS.md#exposing-the-edge--two-paths).

> Note: the chart's default exposure path on AWS is the LoadBalancer Service (NLB), which needs **no** Ingress controller at all. If you only need a public IP, leave `ingress.enabled: false`.

---

## Pods evicted under load / nodes OOM

**Symptom:** `kubectl get events` shows pod evictions or OOMKilled under traffic.

**Diagnose:**

```bash
kubectl get events -n imageengine --sort-by=.lastTimestamp | tail -30
kubectl top pods -n imageengine
kubectl top nodes
```

**Fix:**

Most often this is backend memory or processor CPU. Backend buffers full images in memory between layers — if the limit is too tight it OOMs exactly when traffic spikes. Don't trim backend memory:

```yaml
backend:
  resources:
    requests:
      memory: "2Gi"
    limits:
      memory: "8Gi"
```

For processor, raise CPU requests so the kernel doesn't squeeze it under contention:

```yaml
processor:
  resources:
    requests:
      cpu: "1"
```

See [SIZING.md](SIZING.md) for per-component characteristics.

---

## Commands cheatsheet

```bash
# All chart-managed pods
kubectl get pods -n imageengine -l app=imageengine-kube -o wide

# Live tail any deployment
kubectl logs -f -n imageengine deploy/imageengine-kube-edge
kubectl logs -f -n imageengine deploy/imageengine-kube-backend
kubectl logs -f -n imageengine deploy/imageengine-kube-fetcher
kubectl logs -f -n imageengine deploy/imageengine-kube-processor
kubectl logs -f -n imageengine deploy/imageengine-kube-osc

# What helm thinks the release looks like
helm list -n imageengine
helm get values imageengine-kube -n imageengine
helm get manifest imageengine-kube -n imageengine | less

# Render the chart locally without installing (great for diffing values changes)
helm template imageengine-kube imageengine/imageengine-kube -f imageengine-values.yaml

# Force rollout after secret changes (deployments don't auto-restart on secret edits)
kubectl rollout restart deploy -n imageengine -l app=imageengine-kube

# Quick resource view
kubectl top pods -n imageengine
kubectl top nodes
```

## Next

- [SIZING.md](SIZING.md) — when the fix is "give it more resources."
- [CUSTOMIZATIONS.md](CUSTOMIZATIONS.md) — exact override syntax for every knob mentioned above.
- Your provider doc — when the issue is platform-specific (LB controller, storage class, ingress controller): [AWS](providers/AWS.md), [Azure](providers/AZURE.md), [DigitalOcean](providers/DIGITALOCEAN.md), [GKE](providers/GKE.md), [Linode](providers/LINODE.md), [self-managed](providers/CUSTOM.md).

