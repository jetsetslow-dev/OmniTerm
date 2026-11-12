# A stand-in for the Proxmox VE API (a contract fake, not Proxmox): the documented shapes of the
# calls OmniTerm makes, over HTTPS with a self-signed certificate, on the same pinned Alpine as the
# other fixtures. It proves OmniTerm's client, not Proxmox itself.
FROM alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce
RUN apk add --no-cache python3 openssl
COPY fake_pve.py /usr/local/lib/omniterm/fake_pve.py
COPY start.sh /usr/local/bin/omniterm-proxmox-api
RUN chmod 0755 /usr/local/bin/omniterm-proxmox-api
EXPOSE 8006
CMD ["/usr/local/bin/omniterm-proxmox-api"]
