{{- /*
Security context of every container this chart runs (Pod Security "restricted", ADR-0014 section 3): no privilege
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
