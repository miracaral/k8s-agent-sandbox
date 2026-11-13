# Ops agent image: a small shell and kubectl, nothing else. No model, no credentials.
# What the pod may do is decided by its ServiceAccount (manifests/20-ops-agent.yaml), not by this image.
# Both base images are pinned by digest (the multi-arch index), so a rebuild cannot silently pick up a changed image.
FROM registry.k8s.io/kubectl:v1.36.5@sha256:0667e3f3e6ef435d7cd4c16684244703ebd67314c17511c2a9f87ea44f6cdf6b AS kubectl

FROM alpine:3.22.8@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f
COPY --from=kubectl /bin/kubectl /usr/local/bin/kubectl
USER 65534:65534
ENTRYPOINT ["sleep", "infinity"]
