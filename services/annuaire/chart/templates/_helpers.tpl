{{/*
  Helpers communs au chart annuaire.
*/}}

{{- define "annuaire.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "annuaire.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "annuaire.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "annuaire.labels" -}}
app.kubernetes.io/name: {{ include "annuaire.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: devhub-campus
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{- define "annuaire.selectorLabels" -}}
app.kubernetes.io/name: {{ include "annuaire.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
