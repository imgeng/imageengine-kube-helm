# Akamai Linode (LKE)

ImageEngine Kube on Akamai's Linode Kubernetes Engine (LKE) with `provider: linode`.

LKE is Akamai's managed Kubernetes offering. The product name is still "Linode Kubernetes Engine" and the chart's preset value remains `linode` (because the storage class, CCM annotation prefix, and CLI tooling all still use the `linode-` namespace), but Akamai is the parent brand. Akamai's CDN and edge footprint pairs naturally with image-delivery workloads.

## Recommended cluster

- **LKE on the newest Kubernetes version it offers** (1.35 and 1.36 as of October 2026; the chart minimum is 1.30). LKE upgrades clusters off the versions it retires, so keep up with minor releases.
- **x86-64 worker nodes.** Linode has no arm64 plans, so the chart's arm64 images don't apply here.
- **Dedicated CPU plans.** They are strongly preferred over Shared because the processor is CPU-bound during cache misses. Linode sells several generations side by side (`g6-dedicated-*`, `g7-dedicated-*`, `g8-dedicated-*`), with prices and availability that vary by region. Check `linode-cli linodes types` for your region. Start with 4 to 8 vCPU per node (for example `g6-dedicated-8`, 8 vCPU / 16 GiB), and see [SIZING.md](../SIZING.md) for traffic-tier guidance.
- At least 3 nodes for the chart's topology-spread to be meaningful.
- **An HA control plane** (`--control_plane.high_availability true`, a paid option on standard LKE) for production. LKE Enterprise adds a control-plane SLA and gives every LoadBalancer Service a Premium NodeBalancer automatically, but you don't need it for either HA or Premium NodeBalancers.

## What `provider: linode` configures for you

- **Storage class:** `linode-block-storage-retain` (Linode Block Storage CSI; `retain` keeps the volume on PVC deletion, the safer default for OSC).
- **Ingress class:** none. LKE ships no Ingress controller, so the cluster's default IngressClass serves the Ingress unless you set `ingress.className`.
- **External DNS provider:** `linode` (used by metric tagging only — the chart doesn't deploy ExternalDNS itself).
- **PROXY protocol** on the edge Service when `service.type: LoadBalancer` (see [Client IP](#client-ip)).

You can override any of these explicitly — see [CUSTOMIZATIONS.md](../CUSTOMIZATIONS.md).

## Storage

- `linode-block-storage-retain` is the default. If you'd prefer the volume to be deleted when the PVC is deleted, override to `linode-block-storage`.
- A Block Storage volume is **10 GB to 16 TB**. An account is limited to 250 volumes and 100 TB in total across all regions, so check the account limit before you size a sharded OSC in several clusters.

## LoadBalancer (the edge Service)

The Linode CCM provisions a NodeBalancer for any `Service type: LoadBalancer`. The annotations worth setting:

```yaml
service:
  type: LoadBalancer
  annotations:
    # Keep the NodeBalancer, and the IP your DNS points at, if the Service is deleted.
    service.beta.kubernetes.io/linode-loadbalancer-preserve: "true"
    # After the first install, adopt that NodeBalancer by ID, so a recreated
    # Service gets the same IP instead of a new NodeBalancer.
    service.beta.kubernetes.io/linode-loadbalancer-nodebalancer-id: "1234567"
    # Tags the CCM keeps in sync on the NodeBalancer.
    service.beta.kubernetes.io/linode-loadbalancer-tags: imageengine-prod
```

- **Name.** The CCM has no label annotation. It names a new NodeBalancer `<prefix>-<hash>` and never renames it, so set a readable label once by hand (`linode-cli nodebalancers update <id> --label imageengine-prod`).
- **Throttle.** Leave `linode-loadbalancer-throttle` unset, or `"0"`, which is the CCM's default: no throttle. Any other value (the maximum is 20) limits new connections per second from each client IP. Monitoring services, prefetchers and NATed offices exceed that easily, and the edge's fair-share admission already limits heavy clients more precisely.
- **Capacity.** A standard NodeBalancer handles up to 10,000 concurrent connections. A Premium NodeBalancer handles up to 100,000. Request one with `service.beta.kubernetes.io/linode-loadbalancer-nodebalancer-type: premium`. Premium is billed hourly plus a data-processing fee per GB, which adds up for image traffic. Both are limited to 10 Gbps inbound. Choose the type before DNS points at the NodeBalancer: we haven't found a supported way to change an existing NodeBalancer's type, and a new NodeBalancer means a new IP.
- **Inbound allowlists.** The Linode CCM ignores `service.loadBalancerSourceRanges`. To restrict who can reach the NodeBalancer, use `service.beta.kubernetes.io/linode-loadbalancer-firewall-acl` (a JSON `allowList` or `denyList`, managed by the CCM) or attach your own Cloud Firewall with `linode-loadbalancer-firewall-id`.

### Client IP

With a LoadBalancer Service, `provider: linode` has the NodeBalancer send a PROXY v2 header (`linode-loadbalancer-default-proxy-protocol: v2`) and the edge read it, so fair-share admission and the access log see real client addresses. See [How do I preserve the client IP?](../CUSTOMIZATIONS.md#how-do-i-preserve-the-client-ip), including the two-step upgrade for existing installs.

### Firewall the nodes

**Do this before the cluster takes traffic.** LKE nodes have public IPs, and node pools have no Cloud Firewall by default. Every LoadBalancer Service also opens its NodePorts on every node. A client that connects to a NodePort directly skips the NodeBalancer and can send its own PROXY header, which sets any client IP it likes: it can dodge fair share or get another address throttled.

Put a Cloud Firewall on the nodes that accepts only the NodePort range from the NodeBalancers and the traffic LKE itself needs. Akamai's [recommended LKE rules](https://techdocs.akamai.com/cloud-computing/docs/lke-network-firewall-details), inbound:

| Traffic | Protocol and ports | Source |
|---|---|---|
| NodeBalancers | TCP and UDP 30000-32767 | `192.168.255.0/24` |
| kubelet health checks | TCP 10250, 10256 | `192.168.128.0/17` |
| WireGuard (kubectl proxy) | UDP 51820 | `192.168.128.0/17` |
| Calico BGP | TCP 179 | `192.168.128.0/17` |
| Calico Typha | TCP 5473 | `192.168.128.0/17` |
| Node and control-plane traffic | IPENCAP | `192.168.128.0/17` |

Drop all other inbound TCP and UDP. Nodes the autoscaler adds or a recycle replaces need the firewall too: attach it to the node pool, or run Akamai's Cloud Firewall Controller, which keeps every node on the same ruleset.

To check, connect to a node's public IP on one of the Service's NodePorts from outside Linode. The connection should time out.

## HTTP/3

Terminating HTTP/3 on an ingress controller or gateway behind a NodeBalancer isn't supported: clients get HTTP/2 and HTTP/1.1 there. NodeBalancers can't yet carry HTTP/3 in a way that keeps fair-share admission working. We tested this on October 1, 2026:

- **UDP needs a Premium NodeBalancer, and is a beta.** Standard NodeBalancers, which the CCM creates by default, have no UDP. UDP on Premium NodeBalancers is a beta API feature that Akamai has to enable for your account. Without it, the API answers `UDP protocol option is not allowed`, even for a Premium NodeBalancer.
- **No PROXY protocol over UDP.** NodeBalancers send PROXY headers only on TCP, and the CCM rejects a Service that combines `linode-loadbalancer-default-proxy-protocol` with a UDP port (`proxy protocol [v2] is not supported for UDP`). Whether a UDP NodeBalancer keeps the client's source address is still unconfirmed. If it doesn't, every HTTP/3 visitor shares one fair-share bucket.
- **No TCP and UDP on the same port.** The CCM matches NodeBalancer configs by port number only, so a Service with both `443/TCP` and `443/UDP` (which HTTP/3 needs) fails to sync.

To offer HTTP/3 to your clients on Linode today, terminate it at a CDN in front of the cluster and use `clientIP.mode: forwardedFor` on the cluster side. See [How do I serve HTTP/3?](../CUSTOMIZATIONS.md#how-do-i-serve-http3) for the general requirements.

## Ingress or Gateway

The chart's default LoadBalancer Service needs neither. If you want hostname routing in the cluster, the NodeBalancer fronts your Ingress controller's or Gateway's Service instead of the edge's. Set `service.type: ClusterIP` on the chart so clients can't reach the edge around it, and [firewall the nodes](#firewall-the-nodes) as for the edge Service.

**Gateway API**, for example Envoy Gateway. Attach the chart's `HTTPRoute` to your Gateway:

```yaml
service:
  type: ClusterIP

httpRoute:
  enabled: true
  parentRefs:
    - name: my-gateway
      namespace: gateway       # its listener must allow routes from the release's namespace
  hostnames:
    - images.example.com
```

`clientIP.mode: auto` then trusts the one `X-Forwarded-For` entry the Gateway appends. For that entry to be the client, Envoy has to see the client's address: give the Envoy Service the NodeBalancer PROXY annotation (`linode-loadbalancer-default-proxy-protocol: v2`, under `envoyService.annotations` in the `EnvoyProxy`), and set `proxyProtocol` in a `ClientTrafficPolicy` for the Gateway. See [How do I route through a Gateway?](../CUSTOMIZATIONS.md#how-do-i-route-through-a-gateway-gateway-api).

**An Ingress controller**, such as Traefik, with `ingress.enabled: true`. LKE ships none, and the chart sets no class here, so make your controller the default IngressClass or set `ingress.className`. Enable PROXY protocol between the NodeBalancer and the controller too (see [How do I preserve the client IP?](../CUSTOMIZATIONS.md#how-do-i-preserve-the-client-ip)).

## TLS

Most common: cert-manager with the DNS-01 solver pointed at the Linode DNS API. cert-manager doesn't ship a built-in Linode provider — you'll need a community webhook (search `cert-manager-webhook-linode` on GitHub). If your zone is elsewhere, use that provider's solver instead, such as cert-manager's built-in Route53 solver. HTTP-01 also works once your hostname resolves to the NodeBalancer, but not for wildcards, and not when DNS spreads one hostname across clusters in several regions, because the challenge can land on a cluster that didn't request it.

## DNS

[ExternalDNS](https://github.com/kubernetes-sigs/external-dns) for Linode uses a Personal Access Token with read/write permissions on Domains. Once installed, it picks up Ingress hosts and creates the right records in your Linode-managed zone. Pin the NodeBalancer (see [LoadBalancer](#loadbalancer-the-edge-service)) so the address it publishes survives a reinstall.

## Egress IPs

The fetcher reaches your origins, and every component reaches the ImageEngine endpoints in [REQUIREMENTS.md](../REQUIREMENTS.md#network-egress), from the nodes' own public IPs. Those change whenever the autoscaler adds a node or a node is recycled. If an origin allowlists source addresses, allowlist Linode's address ranges for the region, or send origin traffic through a proxy with a fixed address, rather than listing today's node IPs.

## Sample minimal values

With no `service` or `ingress` settings, the edge gets a NodeBalancer with PROXY protocol. Add the `preserve` and `nodebalancer-id` annotations from [LoadBalancer](#loadbalancer-the-edge-service) once DNS points at it.

```yaml
provider: linode

objectStorageCache:
  persistence:
    size: "500Gi"

processor:
  autoscaling:
    enabled: true
    minReplicas: 3
    maxReplicas: 16
    targetCPUUtilizationPercentage: 80

identity:
  region: us-iad   # the Linode region ID; the provider label follows `provider: linode`
```

## Next

- [GETTING_STARTED.md](../GETTING_STARTED.md) — install steps.
- [CUSTOMIZATIONS.md](../CUSTOMIZATIONS.md) — every override you might want.
- [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) — common issues and fixes.
