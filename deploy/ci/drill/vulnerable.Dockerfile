# drill-vulnerable: an image built ONLY to drill admission.
# It must never run: no chart points to it, and Kyverno must refuse it because its signed vuln attestation lists
# CRITICAL vulnerabilities. Built through the same two-architecture pipeline as the services, so the CRITICAL findings
# are the only difference with a release.
#
# The base is deliberately old and stays old (Renovate leaves this directory alone): Alpine 3.12.0 (2020), pinned by
# the digest of its multi-arch index, for which trivy v0.76.0 reports CRITICAL on both linux/amd64 and linux/arm64
# (apk-tools CVE-2021-36159, OpenSSL CVE-2021-3711, zlib CVE-2022-37434). No secret is added: the secret gate still
# applies to this image.
FROM alpine:3.12.0@sha256:185518070891758909c9f839cf4ca393ee977ac378609f700f60a771a2dfe321
# Not root, as a release: the user changes no package, so the CRITICAL findings stay what they are.
USER 65534:65534
# Exits at once if anything ever starts it.
ENTRYPOINT ["/bin/false"]
