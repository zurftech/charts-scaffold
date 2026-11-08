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
{{- with .Values.component }}
app.kubernetes.io/component: {{ . }}
{{- end }}
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

{{/*
The data block of the configFiles ConfigMap. configmap.yaml and the migration hook's copy in
hook-migration.yaml both render it, so the two never drift apart.
*/}}
{{- define "+( .AppName ).configFilesData" -}}
{{- range $k,$v := .Values.configFiles.files -}}
{{- if eq "string" (printf "%T" $v ) -}}
{{- $k | nindent 0 }}: |-
  {{- $v | nindent 2 -}}
{{- else -}}
{{- $k | nindent 0 }}: |-
  {{- toYaml $v | nindent 2 }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Container settings shared by the restartAfterSync init container and wait containers. kubectl writes
its discovery cache under HOME, so HOME points at a writable emptyDir.
*/}}
{{- define "+( .AppName ).restartAfterSyncContainer" -}}
env:
  - name: HOME
    value: /tmp
volumeMounts:
  - name: tmp
    mountPath: /tmp
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
{{- with .resources }}
resources:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
The app's pods regardless of component: the selector of the NetworkPolicy, which covers the worker too.
*/}}
{{- define "+( .AppName ).appSelectorLabels" -}}
app.kubernetes.io/name: {{ include "+( .AppName ).name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Name of the ExternalSecret and of the Secret it writes. Default: the fullname.
*/}}
{{- define "+( .AppName ).externalSecretName" -}}
{{- (.Values.externalSecret | default dict).name | default (include "+( .AppName ).fullname" .) }}
{{- end }}

{{/*
Secrets passed to the app containers with envFrom, as a JSON list: secretEnv.secretName (when
secretEnv.enabled), then the ExternalSecret's Secret (when externalSecret.enabled, unless
externalSecret.envFrom is false). Deployment, worker and CronJobs read it.
*/}}
{{- define "+( .AppName ).envFromSecrets" -}}
{{- $names := list }}
{{- $envConfig := .Values.secretEnv | default dict }}
{{- if $envConfig.enabled | default false }}
{{- $names = append $names $envConfig.secretName }}
{{- end }}
{{- $es := .Values.externalSecret | default dict }}
{{- if and $es.enabled (ne (toString $es.envFrom) "false") }}
{{- $esName := include "+( .AppName ).externalSecretName" . }}
{{- if not (has $esName $names) }}
{{- $names = append $names $esName }}
{{- end }}
{{- end }}
{{- toJson $names }}
{{- end }}

{{/*
The spec of the app's ExternalSecret. externalsecret.yaml renders it for the app; hook-migration.yaml
renders a hook copy for the migration Job. Called with a dict: root, target (the Secret to write).
*/}}
{{- define "+( .AppName ).externalSecretSpec" -}}
{{- $es := .root.Values.externalSecret }}
{{- if not $es.storeName }}
{{- fail "externalSecret.storeName is required: the ClusterSecretStore (or SecretStore) to read from" }}
{{- end }}
{{- if not (or $es.remoteKey $es.data) }}
{{- fail "externalSecret needs remoteKey (a Secrets Manager secret) or data" }}
{{- end }}
{{- if and $es.keys (not $es.remoteKey) }}
{{- fail "externalSecret.keys needs externalSecret.remoteKey" }}
{{- end }}
refreshInterval: {{ $es.refreshInterval | default "1h" }}
secretStoreRef:
  kind: {{ $es.storeKind | default "ClusterSecretStore" }}
  name: {{ $es.storeName }}
target:
  name: {{ .target }}
  creationPolicy: {{ $es.creationPolicy | default "Owner" }}
  {{- with $es.deletionPolicy }}
  deletionPolicy: {{ . }}
  {{- end }}
{{- if and $es.remoteKey (not $es.keys) }}
dataFrom:
  - extract:
      key: {{ $es.remoteKey | quote }}
{{- end }}
{{- if or $es.keys $es.data }}
data:
  {{- range $es.keys }}
  - secretKey: {{ . | quote }}
    remoteRef:
      key: {{ $es.remoteKey | quote }}
      property: {{ . | quote }}
  {{- end }}
  {{- with $es.data }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
{{- end }}
{{- end }}
