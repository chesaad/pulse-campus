{{/*
  Helpers communs au chart notif.
*/}}

{{- define "notif.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "notif.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "notif.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "notif.labels" -}}
app.kubernetes.io/name: {{ include "notif.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: devhub-campus
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{- define "notif.selectorLabels" -}}
app.kubernetes.io/name: {{ include "notif.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
