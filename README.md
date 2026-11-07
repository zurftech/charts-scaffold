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
