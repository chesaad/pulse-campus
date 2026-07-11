{{/*
  Helpers communs au chart notif.
*/}}

{{- define "notif.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- /*
  fullnameOverride figé à "notif" dans values.yaml : le nom du Service (et
  donc le label Prometheus `service=`) reste stable quel que soit le nom de
  release ArgoCD (ex. "notif-dev").
*/ -}}
{{- define "notif.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "notif.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
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
