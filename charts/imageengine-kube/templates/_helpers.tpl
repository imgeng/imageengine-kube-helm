{{- define "imageengine.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "imageengine.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "imageengine.chart" -}}
{{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/*
OSC sharding client env vars (used by backend, fetcher, processor).
Points the client at the OSC headless Service's SRV record for Kubernetes shard
discovery (ADR 0019): it discovers every shard, sizes to replicaCount
automatically (no per-host OSC{i}_HOST list to hand-maintain — a resize is
picked up within one refresh), and derives each shard's ordinal from its pod
hostname. Routing uses rendezvous/HRW hashing by default (ADR 0020, override via
objectStorageCache.client.hash). The port name "osc" matches the headless
Service's named port, so OSCCLIENT_SRV_PORTNAME is left at its default.
Usage: {{ include "imageengine.oscShardEnv" . | nindent 12 }}
*/}}
{{- define "imageengine.oscShardEnv" -}}
{{- $full := include "imageengine.fullname" . -}}
- name: OSCCLIENT_SRV_NAME
  value: "{{ $full }}-osc-headless.{{ .Release.Namespace }}.svc.cluster.local"
- name: OSCCLIENT_HASH
  value: {{ .Values.objectStorageCache.client.hash | default "hrw" | quote }}
{{- end -}}

{{/*
OpenTelemetry tracing env for a component (ADR 0007). Emits nothing when
otel.enabled is false, so tracing stays fully opt-in. Otherwise sets the
component's *_OTEL_ENABLED flag, the OTLP endpoint (if configured; leave empty
to rely on OpenTelemetry-Operator injection), a default
OTEL_RESOURCE_ATTRIBUTES=deployment.environment=<identity.environment>
(unless the caller supplies OTEL_RESOURCE_ATTRIBUTES in otel.env, which then
wins), and any shared OTEL_* vars. otel.env follows the same scalar/map
convention as a component's env (see imageengine.renderEnv), so a collector
credential such as OTEL_EXPORTER_OTLP_HEADERS can come from a Secret.
Usage: {{ include "imageengine.otelEnv" (dict "ctx" . "enableVar" "EDGE_OTEL_ENABLED") }}
*/}}
{{- define "imageengine.otelEnv" -}}
{{- $otel := .ctx.Values.otel -}}
{{- if and $otel $otel.enabled }}
- name: {{ .enableVar }}
  value: "true"
{{- if $otel.endpoint }}
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: {{ $otel.endpoint | quote }}
{{- end }}
{{- /* Tag every span with the deployment environment out of the box, sourced
       from identity.environment. Skipped when the caller already sets
       OTEL_RESOURCE_ATTRIBUTES in otel.env (their value wins, no duplicate). */ -}}
{{- $env := include "imageengine.appEnv" .ctx -}}
{{- if and $env (not (hasKey (default (dict) $otel.env) "OTEL_RESOURCE_ATTRIBUTES")) }}
- name: OTEL_RESOURCE_ATTRIBUTES
  value: {{ printf "deployment.environment=%s" $env | quote }}
{{- end }}
{{- include "imageengine.renderEnv" $otel.env }}
{{- end }}
{{- end -}}

{{/*
=============================================================================
Provider-Aware Helpers
=============================================================================
These helpers automatically apply provider-specific defaults when the
'provider' value is set, while still allowing explicit overrides.
*/}}

{{/*
Get the storage class based on provider or explicit setting.
Priority: explicit value > provider preset > "standard"
Usage: {{ include "imageengine.storageClass" . }}
*/}}
{{- define "imageengine.storageClass" -}}
{{- if .Values.objectStorageCache.persistence.storageClass -}}
{{- .Values.objectStorageCache.persistence.storageClass -}}
{{- else if and .Values.provider (hasKey .Values.providerPresets .Values.provider) -}}
{{- $preset := index .Values.providerPresets .Values.provider -}}
{{- $preset.storageClass | default "standard" -}}
{{- else -}}
standard
{{- end -}}
{{- end -}}

{{/*
Get the ingress class based on provider or explicit setting.
Priority: explicit value > provider preset > "" (no ingressClassName, so the
cluster's default IngressClass picks the Ingress up).
Usage: {{ include "imageengine.ingressClass" . }}
*/}}
{{- define "imageengine.ingressClass" -}}
{{- if .Values.ingress.className -}}
{{- .Values.ingress.className -}}
{{- else if and .Values.provider (hasKey .Values.providerPresets .Values.provider) -}}
{{- (index .Values.providerPresets .Values.provider).ingressClass | default "" -}}
{{- end -}}
{{- end -}}

{{/*
Get merged ingress annotations (provider defaults + explicit overrides).
Explicit annotations take precedence over provider defaults.
Usage: {{ include "imageengine.ingressAnnotations" . | nindent 4 }}
*/}}
{{- define "imageengine.ingressAnnotations" -}}
{{- $annotations := dict -}}
{{- /* Apply provider preset annotations first, but only when the effective ingress
       class still matches the preset's class. Preset ingress annotations are
       class-specific (e.g. alb.ingress.kubernetes.io/* for AWS), so if the user
       overrides ingress.className to something else we must not inject them. */ -}}
{{- if and .Values.provider (hasKey .Values.providerPresets .Values.provider) -}}
{{- $preset := index .Values.providerPresets .Values.provider -}}
{{- $effectiveClass := include "imageengine.ingressClass" . -}}
{{- if and $preset.ingressAnnotations $preset.ingressClass (eq $effectiveClass $preset.ingressClass) -}}
{{- $annotations = merge $annotations $preset.ingressAnnotations -}}
{{- end -}}
{{- end -}}
{{- /* Merge explicit annotations last so they win on conflicts */ -}}
{{- if .Values.ingress.annotations -}}
{{- $annotations = mergeOverwrite $annotations .Values.ingress.annotations -}}
{{- end -}}
{{- /* Output the annotations */ -}}
{{- range $key, $value := $annotations }}
{{ $key }}: {{ $value | quote }}
{{- end -}}
{{- end -}}

{{/*
Get merged edge Service annotations (provider defaults + explicit overrides).
Explicit service.annotations take precedence over provider defaults, so a
deployment can, for example, set the AWS LB scheme back to "internal".
In clientIP proxyProtocol mode the provider's PROXY protocol annotation is added
too, unless clientIP.proxyProtocol.annotateService is false.
Usage: {{ include "imageengine.serviceAnnotations" . | nindent 4 }}
*/}}
{{- define "imageengine.serviceAnnotations" -}}
{{- $annotations := dict -}}
{{- /* Apply provider preset annotations first */ -}}
{{- if and .Values.provider (hasKey .Values.providerPresets .Values.provider) -}}
{{- $preset := index .Values.providerPresets .Values.provider -}}
{{- if $preset.serviceAnnotations -}}
{{- $annotations = merge $annotations $preset.serviceAnnotations -}}
{{- end -}}
{{- $pp := (.Values.clientIP | default dict).proxyProtocol | default dict -}}
{{- if and $preset.proxyProtocolAnnotations (eq (include "imageengine.clientIPMode" .) "proxyProtocol") (eq .Values.service.type "LoadBalancer") (ne $pp.annotateService false) -}}
{{- $annotations = merge $annotations $preset.proxyProtocolAnnotations -}}
{{- end -}}
{{- end -}}
{{- /* Merge explicit annotations last so they win on conflicts */ -}}
{{- if .Values.service.annotations -}}
{{- $annotations = mergeOverwrite $annotations .Values.service.annotations -}}
{{- end -}}
{{- /* Output the annotations */ -}}
{{- range $key, $value := $annotations }}
{{ $key }}: {{ $value | quote }}
{{- end -}}
{{- end -}}

{{/*
=============================================================================
Client IP (docs/CUSTOMIZATIONS.md, "How do I preserve the client IP?")
=============================================================================
*/}}

{{/*
"true" when images.edge understands the EDGE_CLIENT_IP_SOURCE / EDGE_PROXY_PROTOCOL
settings (edge 4.10.0+), else "". Tags that are not a version (e.g. "latest", a
digest) are assumed to.
*/}}
{{- define "imageengine.edgeSupportsClientIP" -}}
{{- $v := regexFind "^v?[0-9]+\\.[0-9]+\\.[0-9]+" (toString .Values.images.edge) -}}
{{- if or (not $v) (semverCompare ">=4.10.0" $v) -}}true{{- end -}}
{{- end -}}

{{/*
Effective clientIP mode: legacy | direct | proxyProtocol | forwardedFor.
auto picks by how traffic reaches the edge:
  ingress.enabled                                  -> forwardedFor
  LoadBalancer on a provider with a PROXY preset   -> proxyProtocol
  anything else                                    -> direct
and stays legacy while images.edge predates 4.10.0.
Usage: {{ include "imageengine.clientIPMode" . }}
*/}}
{{- define "imageengine.clientIPMode" -}}
{{- $mode := (.Values.clientIP | default dict).mode | default "auto" -}}
{{- if ne $mode "auto" -}}
{{- $mode -}}
{{- else if not (include "imageengine.edgeSupportsClientIP" .) -}}
legacy
{{- else if or .Values.ingress.enabled (.Values.httpRoute | default dict).enabled -}}
forwardedFor
{{- else if and (eq .Values.service.type "LoadBalancer") (include "imageengine.hasProxyProtocolPreset" .) -}}
proxyProtocol
{{- else -}}
direct
{{- end -}}
{{- end -}}

{{/* "true" when the provider preset can make its load balancer send PROXY headers. */}}
{{- define "imageengine.hasProxyProtocolPreset" -}}
{{- if and .Values.provider (hasKey .Values.providerPresets .Values.provider) -}}
{{- if (index .Values.providerPresets .Values.provider).proxyProtocolAnnotations -}}true{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Proxies that append to X-Forwarded-For in forwardedFor mode. clientIP.forwardedHops
0 means auto: 2 for GCE ingress (it appends the client and its own address),
otherwise 1.
*/}}
{{- define "imageengine.forwardedHops" -}}
{{- $hops := int ((.Values.clientIP | default dict).forwardedHops | default 0) -}}
{{- if gt $hops 0 -}}
{{- $hops -}}
{{- else if eq (include "imageengine.ingressClass" .) "gce" -}}
2
{{- else -}}
1
{{- end -}}
{{- end -}}

{{/*
Edge Service externalTrafficPolicy. An explicit service.externalTrafficPolicy
wins. In direct mode on a provider preset without PROXY support (gke, azure) a
LoadBalancer gets Local, since that is the only way its peer is the client.
*/}}
{{- define "imageengine.externalTrafficPolicy" -}}
{{- if .Values.service.externalTrafficPolicy -}}
{{- .Values.service.externalTrafficPolicy -}}
{{- else if and (eq .Values.service.type "LoadBalancer") (eq (include "imageengine.clientIPMode" .) "direct") (has .Values.provider (list "gke" "azure")) -}}
Local
{{- end -}}
{{- end -}}

{{/*
Edge env for the effective clientIP mode. Each var is skipped when edge.env
sets it, so an explicit override wins.
Usage: {{ include "imageengine.clientIPEnv" . | nindent 12 }}
*/}}
{{- define "imageengine.clientIPEnv" -}}
{{- $c := .Values.clientIP | default dict -}}
{{- $env := default (dict) .Values.edge.env -}}
{{- $mode := include "imageengine.clientIPMode" . -}}
{{- if eq $mode "proxyProtocol" }}
{{- include "imageengine.derivedEnv" (dict "name" "EDGE_PROXY_PROTOCOL" "value" (($c.proxyProtocol | default dict).policy | default "optional") "env" $env) }}
{{- end }}
{{- if or (eq $mode "proxyProtocol") (eq $mode "direct") }}
{{- include "imageengine.derivedEnv" (dict "name" "EDGE_CLIENT_IP_SOURCE" "value" "remote-addr" "env" $env) }}
{{- else if eq $mode "forwardedFor" }}
{{- include "imageengine.derivedEnv" (dict "name" "EDGE_CLIENT_IP_SOURCE" "value" "x-forwarded-for" "env" $env) }}
{{- include "imageengine.derivedEnv" (dict "name" "EDGE_XFF_TRUSTED_HOPS" "value" (include "imageengine.forwardedHops" .) "env" $env) }}
{{- end }}
{{- if and (ne $mode "legacy") $c.trustedProxies }}
{{- include "imageengine.derivedEnv" (dict "name" "EDGE_TRUSTED_PROXIES" "value" (join "," $c.trustedProxies) "env" $env) }}
{{- end }}
{{- end -}}

{{/*
Deployment environment name (identity.environment) — the single source of truth,
resolved nil-safely at template time. Feeds the ENVIRONMENT label, every
component's *_SENTRY_ENV / APP_ENV, and the OTel deployment.environment attribute.
Usage: {{ include "imageengine.appEnv" $ }}
*/}}
{{- define "imageengine.appEnv" -}}
{{- (.Values.identity | default dict).environment | default "" -}}
{{- end -}}

{{/*
Effective provider name for the telemetry/logging PROVIDER label.
Uses identity.provider if set, otherwise the top-level provider.
Usage: {{ include "imageengine.providerName" . }}
*/}}
{{- define "imageengine.providerName" -}}
{{- $identity := .Values.identity | default dict -}}
{{- if $identity.provider -}}
{{- $identity.provider -}}
{{- else if .Values.provider -}}
{{- .Values.provider -}}
{{- else -}}
unknown
{{- end -}}
{{- end -}}

{{/*
Deployment-identity env, emitted on every component. Users set friendly camelCase
keys under `identity:` (environment, region, availabilityZone, deploy, product,
hostId, hostname, hostType, hostImage, provider); this helper maps each to the
env var the binaries actually read (ENVIRONMENT, REGION, AZ, DEPLOY, PRODUCT,
HOST_ID, HOSTNAME, HOST_TYPE, HOST_IMAGE) at template time, so the values
interface stays idiomatic and the env-var names are an implementation detail.
Empty labels are omitted. PROVIDER always resolves via providerName. ENVIRONMENT
is the single source of truth (imageengine.appEnv) that also drives *_SENTRY_ENV /
APP_ENV / OTel. Do NOT reintroduce raw UPPERCASE env-var keys under identity.
Usage: {{ include "imageengine.identityEnv" $ | nindent 12 }}
*/}}
{{- define "imageengine.identityEnv" -}}
{{- $id := .Values.identity | default dict -}}
{{- with include "imageengine.appEnv" . }}
- name: ENVIRONMENT
  value: {{ . | quote }}
{{- end }}
- name: PROVIDER
  value: {{ include "imageengine.providerName" . | quote }}
{{- with $id.region }}
- name: REGION
  value: {{ . | quote }}
{{- end }}
{{- with $id.availabilityZone }}
- name: AZ
  value: {{ . | quote }}
{{- end }}
{{- with $id.deploy }}
- name: DEPLOY
  value: {{ . | quote }}
{{- end }}
{{- with $id.product }}
- name: PRODUCT
  value: {{ . | quote }}
{{- end }}
{{- with $id.hostId }}
- name: HOST_ID
  value: {{ . | quote }}
{{- end }}
{{- with $id.hostname }}
- name: HOSTNAME
  value: {{ . | quote }}
{{- end }}
{{- with $id.hostType }}
- name: HOST_TYPE
  value: {{ . | quote }}
{{- end }}
{{- with $id.hostImage }}
- name: HOST_IMAGE
  value: {{ . | quote }}
{{- end }}
{{- end -}}

{{/*
Emit a single env var whose value must track ONE chart-level source of truth
(identity.environment, imageengine.emitterServer, objectStorageCache.storagePath)
resolved at template time — the correct replacement for the values.yaml YAML
anchors that used to freeze these. Skipped when the component's own env map
already defines the key, so an explicit per-component override still wins with no
duplicate key.
Usage: {{ include "imageengine.derivedEnv" (dict "name" "EDGE_EMITTER_SERVER" "value" $.Values.imageengine.emitterServer "env" $.Values.edge.env) | nindent 12 }}
*/}}
{{- define "imageengine.derivedEnv" -}}
{{- if not (hasKey (default (dict) .env) .name) }}
- name: {{ .name }}
  value: {{ .value | default "" | quote }}
{{- end }}
{{- end -}}

{{/*
Emit a built-in env var sourced from one of the chart's own Secrets. Skipped when
the component's env map already defines the key, so an operator who keeps the
value in a differently-named Secret (or supplies it some other way) gets their
definition instead of a duplicate name.
Usage: {{ include "imageengine.secretEnv" (dict "name" "EDGE_API_KEY" "secret" "ie-kube-api-key" "key" "KEY" "env" $.Values.edge.env) | nindent 12 }}
*/}}
{{- define "imageengine.secretEnv" -}}
{{- if not (hasKey (default (dict) .env) .name) }}
- name: {{ .name }}
  valueFrom:
    secretKeyRef:
      name: {{ .secret }}
      key: {{ .key }}
      {{- if .optional }}
      optional: true
      {{- end }}
{{- end }}
{{- end -}}

{{/*
Render a component's `env` map as a container env list. A scalar value sets the
variable's `value:`; a mapping value is emitted as its `valueFrom:` (e.g.
secretKeyRef / configMapKeyRef / fieldRef), so a variable can be sourced from a
Secret or ConfigMap instead of being inlined. Keys already emitted above a call
site should not be repeated here (a duplicate name breaks `helm upgrade`).
Usage: {{ include "imageengine.renderEnv" .Values.edge.env | nindent 12 }}
*/}}
{{- define "imageengine.renderEnv" -}}
{{- range $k, $v := . }}
- name: {{ $k }}
{{- if kindIs "map" $v }}
  valueFrom:
    {{- toYaml $v | nindent 4 }}
{{- else }}
  value: {{ $v | quote }}
{{- end }}
{{- end }}
{{- end -}}

