# Repository-built, checksum-verified Go module and userspace networking; no host TUN or privileges.
FROM alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce
COPY .build/nebulalab /usr/local/bin/nebulalab
ENTRYPOINT ["/usr/local/bin/nebulalab"]
