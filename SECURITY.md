# Security Policy

## Reporting a Vulnerability

This is a personal homelab project maintained by one person in spare time.
There is no formal security response team, no embargo process, and no
coordinated disclosure window.

For security-relevant issues:

- **Vulnerabilities in upstream Jellyfin**: report to the upstream
  Jellyfin project at https://github.com/jellyfin/jellyfin/security — they
  have a real security policy and the resources to triage CVEs.
- **Issues specific to the lidslabs patches in this repo**: open a public
  GitHub issue at https://github.com/lidslabs/jellyfin-hdr/issues.

Public issues are acceptable because the threat model for this image is a
self-hosted Jellyfin server typically reached only over LAN or VPN. If you
believe an issue warrants private disclosure, contact via the email on
[my GitHub profile](https://github.com/lidslabs), but expect a best-effort
response time, not a SLA.

## Supported Versions

Only the most recent tagged release receives fixes. Older tags remain
pullable from ghcr.io for rollback purposes but are not patched.
