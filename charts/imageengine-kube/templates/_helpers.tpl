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
Emits OSCCLIENT_ENVCONFIG plus one OSC{i}_HOST per shard ordinal, each pointing
at the StatefulSet pod's stable headless DNS name on the OSC container port
(8000). The OSC sharding client consistent-hashes the origin key across these
nodes. With replicaCount=1 this reproduces the legacy single-node config.
Usage: {{ include "imageengine.oscShardEnv" . | nindent 12 }}
*/}}
{{- define "imageengine.oscShardEnv" -}}
{{- $full := include "imageengine.fullname" . -}}
- name: OSCCLIENT_ENVCONFIG
  value: "true"
{{- range $i := until (int .Values.objectStorageCache.replicaCount) }}
- name: OSC{{ $i }}_HOST
  value: "{{ $full }}-osc-{{ $i }}.{{ $full }}-osc-headless:8000"
{{- end }}
{{- end -}}

{{/*
OpenTelemetry tracing env for a component (ADR 0007). Emits nothing when
otel.enabled is false, so tracing stays fully opt-in. Otherwise sets the
component's *_OTEL_ENABLED flag, the OTLP endpoint (if configured; leave empty
to rely on OpenTelemetry-Operator injection), a default
OTEL_RESOURCE_ATTRIBUTES=deployment.environment=<identity.environment>
(unless the caller supplies OTEL_RESOURCE_ATTRIBUTES in otel.env, which then
wins), and any shared OTEL_* vars.
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
{{- range $key, $value := $otel.env }}
- name: {{ $key }}
  value: {{ $value | quote }}
{{- end }}
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
Priority: explicit value > provider preset > "nginx"
Usage: {{ include "imageengine.ingressClass" . }}
*/}}
{{- define "imageengine.ingressClass" -}}
{{- if .Values.ingress.className -}}
{{- .Values.ingress.className -}}
{{- else if and .Values.provider (hasKey .Values.providerPresets .Values.provider) -}}
{{- $preset := index .Values.providerPresets .Values.provider -}}
{{- $preset.ingressClass | default "nginx" -}}
{{- else -}}
nginx
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
{{- if and $preset.ingressAnnotations (eq $effectiveClass ($preset.ingressClass | default "nginx")) -}}
{{- $annotations = merge $annotations $preset.ingressAnnotations -}}
{{- end -}}
{{- end -}}
{{- /* Merge explicit annotations (these take precedence) */ -}}
{{- if .Values.ingress.annotations -}}
{{- $annotations = merge $annotations .Values.ingress.annotations -}}
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

