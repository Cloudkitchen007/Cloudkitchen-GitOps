{{/* Full image reference for a service entry.
     Uses per-service imageTags.<name> so each service can be deployed
     independently without touching the other services' tags. */}}
{{- define "cloudkitchen.image" -}}
{{- $tag := index .root.Values.imageTags .svc.name -}}
{{- printf "%s/%s:%s" .root.Values.global.ecrRegistry .svc.repo $tag -}}
{{- end -}}

{{/* Common labels */}}
{{- define "cloudkitchen.labels" -}}
app.kubernetes.io/part-of: cloudkitchen
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
