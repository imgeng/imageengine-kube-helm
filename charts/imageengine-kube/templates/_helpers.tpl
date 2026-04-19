{{- define "imageengine.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "imageengine.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else }}
{{- include "imageengine.name" . }}-{{ .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end -}}
{{- end -}}

{{- define "imageengine.chart" -}}
{{ .Chart.Name }}-{{ .Chart.Version }}
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
{{- /* Apply provider preset annotations first */ -}}
{{- if and .Values.provider (hasKey .Values.providerPresets .Values.provider) -}}
{{- $preset := index .Values.providerPresets .Values.provider -}}
{{- if $preset.ingressAnnotations -}}
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
Get the external DNS provider based on provider or explicit setting.
Priority: explicit value > provider preset > ""
Usage: {{ include "imageengine.externalDnsProvider" . }}
*/}}
{{- define "imageengine.externalDnsProvider" -}}
{{- if .Values.externalDns.provider -}}
{{- .Values.externalDns.provider -}}
{{- else if and .Values.provider (hasKey .Values.providerPresets .Values.provider) -}}
{{- $preset := index .Values.providerPresets .Values.provider -}}
{{- $preset.externalDnsProvider | default "" -}}
{{- else -}}
{{- "" -}}
{{- end -}}
{{- end -}}

{{/*
Get the effective provider name for identity/logging.
Uses identity.PROVIDER if set, otherwise falls back to provider.
Usage: {{ include "imageengine.providerName" . }}
*/}}
{{- define "imageengine.providerName" -}}
{{- if .Values.identity.PROVIDER -}}
{{- .Values.identity.PROVIDER -}}
{{- else if .Values.provider -}}
{{- .Values.provider -}}
{{- else -}}
unknown
{{- end -}}
{{- end -}}

