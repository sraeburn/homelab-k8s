{{- define "demo-service.selectorLabels" -}}
app.kubernetes.io/name: demo-service
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "demo-service.labels" -}}
{{ include "demo-service.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
