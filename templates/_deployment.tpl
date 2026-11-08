{{- /*
One Deployment, shared by the app's Deployment (deployment.yaml) and the optional worker (worker.yaml).
Called with a dict:
  root       the chart's root context
  vals       the values to render: .Values for the app, a merged copy for the worker
  name       Deployment name
  labels     metadata labels
  selector   selector labels, also set on the pods
  configMap  the configFiles ConfigMap to mount
  checksum   value of the checksum/config pod annotation, empty for none
Every key added after charts-scaffold 2026-11 renders nothing while unset, so an app that does not set it
renders exactly as before.
*/ -}}
{{- define "+( .AppName ).deployment" -}}
{{- $root := .root }}
{{- $vals := .vals }}
{{- $envPrefix := coalesce $vals.generatedEnvPrefix  "" }}
{{- $portName := coalesce $vals.service.portName  "HTTP" }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .name }}
  {{- with $vals.deployAnnotations }}
  annotations:
    {{- toYaml . | nindent 8 }}
  {{- end }}
  labels:
    {{- .labels | nindent 4 }}
spec:
  revisionHistoryLimit: {{ hasKey $vals "revisionHistoryLimit" | ternary $vals.revisionHistoryLimit 1 }}
  {{- if not $vals.autoscaling.enabled }}
  replicas: {{ $vals.replicaCount }}
  {{- end }}
  {{- with $vals.strategy }}
  strategy:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  selector:
    matchLabels:
      {{- .selector | nindent 6 }}
  template:
    metadata:
      {{- $podAnnotations := deepCopy ($vals.podAnnotations | default dict) }}
      {{- if .checksum }}
      {{- /*
        Hashing the ConfigMap into the pod template rolls the pods when config changes,
        so they never keep running on the config they started with. It also makes the
        Deployment differ, which re-runs the migration hook on config-only changes.
      */}}
      {{- $_ := set $podAnnotations "checksum/config" .checksum }}
      {{- end }}
      {{- if ($vals.externalSecret | default dict).enabled }}
      {{- /* Rolls the pods when the ExternalSecret's spec changes (keys added or removed). */}}
      {{- $_ := set $podAnnotations "checksum/externalsecret" (include (print $root.Template.BasePath "/externalsecret.yaml") $root | sha256sum) }}
      {{- end }}
      {{- with $podAnnotations }}
      annotations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      labels:
        {{- .selector | nindent 8 }}
        {{- with $vals.podLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
    spec:
      {{- with $vals.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      serviceAccountName: {{ include "+( .AppName ).serviceAccountName" $root }}
      {{- if not (kindIs "invalid" $vals.automountServiceAccountToken) }}
      automountServiceAccountToken: {{ $vals.automountServiceAccountToken }}
      {{- end }}
      {{- if not (kindIs "invalid" $vals.enableServiceLinks) }}
      enableServiceLinks: {{ $vals.enableServiceLinks }}
      {{- end }}
      {{- if not (kindIs "invalid" $vals.terminationGracePeriodSeconds) }}
      terminationGracePeriodSeconds: {{ $vals.terminationGracePeriodSeconds }}
      {{- end }}
      securityContext:
        {{- toYaml $vals.podSecurityContext | nindent 8 }}
      {{- with $vals.initContainers }}
      initContainers:
        {{- tpl (toYaml .) $root | nindent 8 }}
      {{- end }}
      containers:
        - name: {{ $root.Chart.Name }}
          securityContext:
            {{- toYaml $vals.securityContext | nindent 12 }}
          image: "{{ $vals.image.repository }}:{{ $vals.image.tag | default $root.Chart.AppVersion }}"
          imagePullPolicy: {{ $vals.image.pullPolicy }}
          {{- $secretNames := include "+( .AppName ).envFromSecrets" $root | fromJsonArray }}
          {{- if $secretNames }}
          envFrom:
          {{- range $secretNames }}
          - secretRef:
              name: {{ . | quote }}
          {{- end }}
          {{- end }}
          {{- if $vals.entrypoint.command }}
          command:
          {{- toYaml $vals.entrypoint.command  | nindent 10 }}
          {{- end }}
          {{- if $vals.entrypoint.args }}
          args:
          {{- toYaml $vals.entrypoint.args  | nindent 10 }}
          {{- end }}
          env:
          {{- if $vals.service.port }}
          - name: {{ cat $envPrefix "PORT_" $portName | nospace |upper}}
            value: {{ $vals.service.port | quote }}
          {{- else if $vals.service.ports }}
          {{- range $k, $v := $vals.service.ports }}
          {{- if $v.port }}
          - name: {{ cat $envPrefix "PORT_" $v.name |nospace |upper }}
            value: {{ $v.port | quote }}
          {{- end }}
          {{- end }}
          {{- end }}
          {{- range $k, $v := $vals.env }}
          - name: {{ $k }}
            value: "{{ $v }}"
          {{- end }}
          ports:
          {{- if $vals.service.port }}
          - containerPort: {{$vals.service.appPort}}
            protocol: TCP
            name: {{ $vals.service.portName | default "http" }}
          {{- else if $vals.service.ports }}
          {{- range $k, $v := $vals.service.ports }}
          {{- if and $v.port $v.name }}
          - containerPort: {{ $v.appPort}}
            protocol: TCP
            name: {{ $v.name }}
          {{- end }}
          {{- end }}
          {{- end }}
          {{- if $vals.livenessProbe }}
          livenessProbe:
            {{- toYaml $vals.livenessProbe | nindent 12 }}
          {{- end }}
          {{- if $vals.readinessProbe }}
          readinessProbe:
            {{- toYaml $vals.readinessProbe | nindent 12 }}
          {{- end }}
          {{- if $vals.startupProbe }}
          startupProbe:
            {{- toYaml $vals.startupProbe | nindent 12 }}
          {{- end }}
          {{- with $vals.lifecycle }}
          lifecycle:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          resources:
            {{- toYaml $vals.resources | nindent 12 }}
          volumeMounts:
          {{- if $vals.configFiles.enabled }}
          - name: configfiles
            mountPath: {{ $vals.configFiles.mountPath }}
            readOnly: true
          {{- end }}
          {{- if $vals.persistence.enabled }}
          - name: persistence
            mountPath: {{ $vals.persistence.mountPath }}
          {{- end }}
          {{- with $vals.extraVolumeMounts }}
          {{- toYaml . | nindent 10 }}
          {{- end }}
      {{- with $vals.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $vals.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $vals.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $vals.topologySpreadConstraints }}
      topologySpreadConstraints:
        {{- tpl (toYaml .) $root | nindent 8 }}
      {{- end }}
      volumes:
      {{- if $vals.configFiles.enabled }}
      - name: configfiles
        configMap:
          name: {{ .configMap }}
      {{- end }}
      {{- if $vals.persistence.enabled }}
      - name: persistence
        persistentVolumeClaim:
          claimName: {{  $vals.persistence.pvcName }}
      {{- end }}
      {{- with $vals.extraVolumes }}
      {{- tpl (toYaml .) $root | nindent 6 }}
      {{- end }}
{{- end }}
