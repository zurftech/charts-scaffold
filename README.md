# charts-scaffold

Base Helm chart for Captain Fresh apps. crood (core/crood) downloads it at build time, merges the app's
`.crood/values.yaml` into `values.yaml`, fills the `+( .AppName )` / `+( .ImageRepository )` placeholders and
publishes the result as the app's chart. Environment repos (e.g. chopserve-prod) override values per environment.

## configFiles

`configFiles.files` renders one ConfigMap named `<fullname>`, mounted at `configFiles.mountPath` in the
Deployment and CronJob pods. It is a normal resource, not a Helm hook, so Argo CD diffs it and applies
config-only changes. The pod template carries a `checksum/config` annotation, so a config change also rolls
the pods.

When `migrations.enabled` is also on, the migration Job runs as a pre-install/pre-upgrade hook (Argo CD
PreSync), before the normal resources. It mounts a hook copy of the same data, `<fullname>-migration-config`,
so it sees the new config on upgrades and works on a fresh install.

A custom `hook.job` that runs as a pre-install/pre-upgrade hook must not mount `<fullname>`: on a fresh
install that ConfigMap does not exist yet. Mount `<fullname>-migration-config` instead, with
`migrations.enabled` on.

## restartAfterSync

Off by default. Restarts other Deployments in the release namespace after every successful sync. Use it for a
client that reads this app only at startup: for example apollo-router, which composes its supergraph by
introspecting the subgraphs once, when its pod starts.

```yaml
restartAfterSync:
  enabled: true
  deployments: [apollo-router]
  # image: registry.k8s.io/kubectl:v1.36.4   # keep within one minor of the cluster
  # timeout: 5m                              # per Deployment; a timeout fails the sync
```

The Job is an Argo CD PostSync hook (Helm post-install/post-upgrade), so it runs only once this release's
resources are Healthy, which means the new pods are already serving. It renders a ServiceAccount, a Role that can
only get, list, watch and patch the listed Deployments, and a RoleBinding, all as normal resources. An init
container runs `kubectl rollout restart` and one container per Deployment waits on `kubectl rollout status`.

It runs on every sync of this app, including config-only ones.

## CronJobs

Off by default: `cronJobs: []` renders nothing, so existing apps are unchanged. Each entry becomes a
`batch/v1` CronJob named `<fullname>-<name>` that runs the app image (or `image`) with the Deployment's service
account, pull secrets, pod and container security context, `secretEnv`, `env` (the entry's `env` wins per key),
`configFiles` / `persistence` mounts and scheduling constraints. Job pods carry the job labels
(`<chart>-jobs`), so the app's Service never selects them.

```yaml
cronJobs:
  - name: nightly-report
    schedule: "30 20 * * *"        # UTC unless timeZone is set (Kubernetes >= 1.27)
    args: ["report", "--nightly"]
    concurrencyPolicy: Forbid      # default Forbid
    activeDeadlineSeconds: 1800
```

All keys are listed, commented, under `cronJobs` in `values.yaml`.

## multiIngress kongPlugins

Each `multiIngress` entry of class `kong` may carry `kongPlugins`, a map of Kong plugins for that Ingress
only. Every key renders one namespaced `KongPlugin` named `<fullname>-<index>-<key>` and appends that name to
the Ingress's `konghq.com/plugins` annotation, after any names already there. Other entries are untouched, so a
service can set its own limit on one route and leave the rest on the gateway's defaults.

```yaml
multiIngress:
  - className: kong
    annotations:
      konghq.com/strip-path: 'false'
    kongPlugins:
      rate-limit:
        plugin: rate-limiting
        config:
          minute: 12000
    hosts:
      - host: api.example.com
        paths:
          - path: /svc/mcp
            pathType: Prefix
```

`config` is passed to Kong as written. For `plugin: rate-limiting` only, the chart fills in `limit_by: ip`,
`policy: local`, `fault_tolerant: true` and `hide_client_headers: false` wherever the entry does not set them.

A plugin attached to a route replaces a global plugin of the same type for that route. Each gateway runs a
global `rate-limiting` (kong-deployment), so a `rate-limiting` entry here is that route's whole limit: it can
be higher or lower than the global one. `policy: local` counts per Kong pod, so the real ceiling per IP is
`minute` x Kong replicas; a gateway with a Redis counter store (kong-deployment cluster values) can be used
with `policy: redis` and its `redis_host`.

A key set to `null` renders nothing. Charts built before this feature ignore `kongPlugins`, so the Ingress
keeps working, just without the plugin.

## externalSecret

Off by default. Renders one `external-secrets.io/v1` ExternalSecret that writes the Secret `<externalSecret.name>`
(default: the fullname) and passes it with `envFrom` to the app container, the worker, every CronJob and the
migration Job, next to `secretEnv` (both can be on). On euphoria the stores are the ClusterSecretStores of
external-secrets-euphoria: `aws-secretsmanager` (cf-eu-prod) and `aws-secretsmanager-dev` (cf-eu-dev), over Secrets
Manager keys `euphoria/<namespace>/<app>`.

```yaml
externalSecret:
  enabled: true
  storeName: aws-secretsmanager            # required
  remoteKey: euphoria/cf-eu-prod/my-app    # alone: every top-level key of the JSON secret
  # keys: [CF_DATABASE_POSTGRES_DSN]       # or only these keys
  # data:                                  # extra entries, as written
  #   - secretKey: API_KEY
  #     remoteRef: {key: euphoria/cf-eu-prod/other, property: API_KEYS}
  # name: my-app-env                       # Secret name, default <fullname>
  # deletionPolicy: Retain
  # envFrom: false                         # create the Secret without passing it as envFrom
```

The pods carry a `checksum/externalsecret` annotation, so adding or removing a key rolls them. Value changes in
Secrets Manager do not: use Reloader (`deployAnnotations: {secret.reloader.stakater.com/reload: <name>}`).

**Migration Job.** It runs before the release's normal resources (Helm pre-install / pre-upgrade, Argo CD PreSync),
so on a fresh install the ExternalSecret's Secret does not exist yet. With `externalSecret` on, the chart renders a
hook copy, ExternalSecret `<fullname>-migration` (weight 0; Argo CD waits for it to be Healthy), and the Job (weight
5) reads that Secret. `migrations.secretEnv` controls whether the Job gets the app's secrets at all: default true
when `externalSecret` is on, false otherwise, which is how every earlier chart behaved (`secretEnv` alone never
reached the Job). Set `migrations.secretEnv: true` to pass `secretEnv` to the Job too.

## worker

Off by default. A second Deployment, `<fullname>-<worker.name>` (default `<fullname>-worker`), for work that must
run in one process only: pollers, schedulers, sync loops. It runs the app's pod (image, service account, init
containers, secrets, probes, volumes, scheduling) with 1 replica and strategy `Recreate`, so a rollout stops the old
pod before the new one starts and two workers never overlap. No HPA.

It needs `component` set (for example `api`): the app's Deployment, Service and PodDisruptionBudget then select
`app.kubernetes.io/component: api` and the worker pods carry `app.kubernetes.io/component: worker`, so no Service
routes to the worker and the two Deployments' selectors never overlap. The chart fails to render otherwise.
Setting `component` on a live app changes its Deployment's selector, which Kubernetes refuses in place: plan it as a
re-create, or set it from the start.

```yaml
component: api
worker:
  enabled: true
  # replicas, strategy, entrypoint, resources, livenessProbe, readinessProbe, startupProbe: replace the app's
  # env, podAnnotations: merged over the app's, key by key
  configFiles:
    files:
      config.yaml:                    # merged over the app's config.yaml, top-level key by key
        integration.sync.enable: true
```

With `worker.configFiles.files` set, the worker mounts its own ConfigMap `<fullname>-<worker.name>`: the app's files
with the worker's merged in (a map file top-level key by key, which fits flat dotted config files; a string file is
replaced). Otherwise it mounts the app's ConfigMap.

## Pod and Deployment settings

All off or empty by default, passed through as written:

| Key | Renders |
| --- | --- |
| `revisionHistoryLimit` | `spec.revisionHistoryLimit` (default 1, as before) |
| `strategy` | `spec.strategy` |
| `podLabels` | extra pod labels (not selector labels) |
| `automountServiceAccountToken`, `enableServiceLinks`, `terminationGracePeriodSeconds` | the pod fields, when set |
| `lifecycle` | the app container's lifecycle (e.g. a `preStop` sleep) |
| `topologySpreadConstraints` | the pod field, rendered with `tpl` |
| `initContainers` | init containers, rendered with `tpl`, so `image: '{{ .Values.image.repository }}:{{ .Values.image.tag \| default .Chart.AppVersion }}'` runs the app image |
| `extraVolumes`, `extraVolumeMounts` | pod volumes (`tpl`) and app container mounts, e.g. an `emptyDir` an init container fills. The `configFiles` volume is named `configfiles`, so an init container can mount it too |
| `podDisruptionBudget` | a `policy/v1` PDB over the app's selector: `minAvailable` (default 1) or `maxUnavailable`, `unhealthyPodEvictionPolicy` |
| `networkPolicy` | a NetworkPolicy over every pod of the app (worker included) with the `ingress` / `egress` rules as written (`tpl`); `policyTypes` default Ingress, plus Egress when egress rules are set |

Kong upstream timeouts go on the Service with `service.annotations` (e.g. `konghq.com/read-timeout`) and IRSA on
the ServiceAccount with `serviceAccount.annotations`; both existed before.

## Checking a change

Every app chart is this template at the commit on `main` when the app was tagged, so a change here reaches every app
on its next tag. Render each environment repo's apps (`chart:` entries from charts.liberty.captainfresh.in) with
`main` and with the change, crood's `+( .AppName )` / `+( .ImageRepository )` substitution simulated, and compare:
with the new values unset the output must be byte-identical.
