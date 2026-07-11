{{/*
  Helpers communs au chart planning.
*/}}

{{- define "planning.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "planning.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "planning.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "planning.labels" -}}
app.kubernetes.io/name: {{ include "planning.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: devhub-campus
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{- define "planning.selectorLabels" -}}
app.kubernetes.io/name: {{ include "planning.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
