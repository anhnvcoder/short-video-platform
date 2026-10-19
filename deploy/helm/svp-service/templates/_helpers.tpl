{{- /*
Labels of the service's own pods. app.kubernetes.io/name is the service name, the label the policies of svp-data
open their servers to; component tells the service's pods (server) from its migrate Job's (migrate), so the Service
and the policies of the server never select a Job pod.
*/}}
{{- define "svp-service.selectorLabels" -}}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/component: server
{{- end }}

{{- define "svp-service.labels" -}}
app.kubernetes.io/name: {{ .Release.Name }}
app.kubernetes.io/part-of: svp
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- /*
The image, with a tag that must be set: the dev tag `make k8s-up` passes, or a release's tag in the values file.
*/}}
{{- define "svp-service.image" -}}
{{- $msg := printf "image.tag is empty for release %s:" .Release.Name -}}
{{- $msg = printf "%s make k8s-up passes the dev tag with --set image.tag=..., a release writes it in" $msg -}}
{{- $msg = printf "%s deploy/k8s/values/services/%s.yaml" $msg .Release.Name -}}
{{- $tag := required $msg .Values.image.tag -}}
{{ required (printf "image.repository is empty for release %s" .Release.Name) .Values.image.repository }}:{{ $tag }}
{{- end }}

{{- /*
Security context of every pod and container (threat model FF-4; Pod Security "restricted" of namespace svp): the
images' non-root user 65532, which runAsNonRoot makes the kubelet check, seccomp RuntimeDefault, no privilege
escalation, no capability, a read-only root filesystem (whatever a process writes goes to a declared emptyDir).
*/}}
{{- define "svp-service.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: 65532
runAsGroup: 65532
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{- define "svp-service.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end }}

{{- /*
A peer of .Values.peers as one entry of a NetworkPolicy's `from` or `to`: its namespace and its pods' labels.
*/}}
{{- define "svp-service.peerSelector" -}}
- namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: {{ .namespace }}
  podSelector:
    matchLabels:
      {{- toYaml .labels | nindent 6 }}
{{- end }}
