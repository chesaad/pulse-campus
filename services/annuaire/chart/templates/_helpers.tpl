{{/*
  Helpers communs au chart annuaire.
*/}}

{{- define "annuaire.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- /*
  fullnameOverride figé à "annuaire" dans values.yaml : le nom du Service (et
  donc le label Prometheus `service=`) reste stable quel que soit le nom de
  release ArgoCD (ex. "annuaire-dev"), pour que le PromQL service="annuaire"
  fonctionne pareil dans tous les environnements.
*/ -}}
{{- define "annuaire.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "annuaire.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
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
