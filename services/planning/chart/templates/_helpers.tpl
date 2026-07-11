{{/*
  Helpers communs au chart planning.
*/}}

{{- define "planning.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- /*
  fullnameOverride figé à "planning" dans values.yaml : le nom du Service (et
  donc le label Prometheus `service=`) reste stable quel que soit le nom de
  release ArgoCD (ex. "planning-dev").
*/ -}}
{{- define "planning.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "planning.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
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
