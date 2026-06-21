{{/* Full image reference for a service entry */}}
{{- define "cloudkitchen.image" -}}
{{- printf "%s/%s:%s" .root.Values.global.ecrRegistry .svc.repo .root.Values.global.imageTag -}}
{{- end -}}

{{/* Common labels */}}
{{- define "cloudkitchen.labels" -}}
app.kubernetes.io/part-of: cloudkitchen
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
