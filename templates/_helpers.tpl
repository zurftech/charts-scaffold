{{/*
Expand the name of the chart.
*/}}
{{- define "+( .AppName ).name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Expand the job names in the chart.
*/}}
{{- define "+( .AppName ).jobname" -}}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- printf "%s-jobs" $name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "+( .AppName ).fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "+( .AppName ).chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "+( .AppName ).labels" -}}
helm.sh/chart: {{ include "+( .AppName ).chart" . }}
{{ include "+( .AppName ).selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "+( .AppName ).joblabels" -}}
helm.sh/chart: {{ include "+( .AppName ).chart" . }}
app.kubernetes.io/name: {{ include "+( .AppName ).jobname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "+( .AppName ).selectorLabels" -}}
app.kubernetes.io/name: {{ include "+( .AppName ).name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
/*
app.kubernetes.io/app: {{ include "+( .AppName ).name" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
*/
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "+( .AppName ).serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "+( .AppName ).fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
