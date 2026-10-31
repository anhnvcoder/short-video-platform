{{- /*
Security context of every container this chart runs (Pod Security "restricted"): no privilege
escalation, no capability, a read-only root filesystem (whatever a process writes goes to a declared volume).
*/}}
{{- define "svp-data.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end }}

{{- /*
Pod security context for the user and group id given (the image's own non-root user): runAsNonRoot makes the kubelet
refuse to start the pod as root even if the id is wrong, seccomp RuntimeDefault filters the syscalls.
*/}}
{{- define "svp-data.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: {{ .uid }}
runAsGroup: {{ .gid }}
{{- if .fsGroup }}
fsGroup: {{ .gid }}
{{- end }}
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{- /*
Annotations of the init Jobs: Helm hooks run after every install and upgrade, once the release's ordinary resources
(NetworkPolicies, ConfigMaps, Services) exist and, with --wait, are ready. A new run replaces the last Job, whose pod
stays until then for its log. Argo CD reads these as PostSync hooks.
*/}}
{{- define "svp-data.initJobAnnotations" -}}
helm.sh/hook: post-install,post-upgrade
helm.sh/hook-delete-policy: before-hook-creation
{{- end }}

{{- /*
"true" when Postgres is outside the cluster (postgres.mode external), "" when CloudNativePG runs it here; fails on any
other mode, or on external without the host or the CIDRs.
*/}}
{{- define "svp-data.postgresExternal" -}}
{{- $pg := .Values.postgres }}
{{- if not (has $pg.mode (list "cluster" "external")) }}
{{- fail (printf "postgres.mode is %q: cluster (CloudNativePG in the cluster) or external (a managed Postgres)" (toString $pg.mode)) }}
{{- end }}
{{- if eq $pg.mode "external" }}
{{- if not $pg.external.host }}
{{- fail "postgres.mode external needs postgres.external.host, the DNS name of the managed Postgres" }}
{{- end }}
{{- if not $pg.external.cidrs }}
{{- fail "postgres.mode external needs postgres.external.cidrs, the CIDRs of the managed Postgres's addresses" }}
{{- end }}
{{- print "true" }}
{{- end }}
{{- end }}

{{- /*
"true" when the object store is outside the cluster (s3.mode external), "" when s3 runs here; fails on any other mode,
and on external while CloudNativePG in the cluster still archives its WAL into s3.
*/}}
{{- define "svp-data.s3External" -}}
{{- if not (has .Values.s3.mode (list "cluster" "external")) }}
{{- fail (printf "s3.mode is %q: cluster (the object store s3 in the cluster) or external (a managed object store)" (toString .Values.s3.mode)) }}
{{- end }}
{{- if eq .Values.s3.mode "external" }}
{{- if not (include "svp-data.postgresExternal" .) }}
{{- fail "s3.mode external needs postgres.mode external: CloudNativePG archives the WAL and base backups of svp-pg into the object store s3 of the cluster" }}
{{- end }}
{{- print "true" }}
{{- end }}
{{- end }}
