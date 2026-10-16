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
