# 0008. Certificates by ACME DNS-01 through Cloudflare, not HTTP-01 or Cloudflare's edge cert

**Status:** Accepted (2026-09-18)

## Context

`jobs.mgryn.cc` needed a real, publicly trusted certificate. Cloudflare
already terminates TLS for `mgryn.cc` at its edge, but `jobs.mgryn.cc`
resolves to `10.0.0.101` — traffic to a private address never reaches
that edge, so Cloudflare's certificate has nothing to do. HTTP-01
validation requires Let's Encrypt to reach the host from the public
internet, which nothing here is.

## Decision

Use cert-manager with ACME DNS-01 against Cloudflare: it proves domain
control by writing a `_acme-challenge` TXT record rather than answering an
inbound request, which a machine on a private address can do. The
Cloudflare API token (`kv-dev/cert-manager/cloudflare`) needs both
`Zone:DNS:Edit` and `Zone:Zone:Read` — edit alone fails the zone lookup
with an error that reads like a DNS fault. Two issuers exist,
`letsencrypt-staging` and `letsencrypt-prod`; staging proved the path
first (Ready in ~4.5 minutes) before cutting to production.

## Consequences

Renewal is automatic and needs nothing reachable from the internet. The
one sharp edge: pinning cert-manager's propagation check to Cloudflare's
own recursive resolvers (`--dns01-recursive-nameservers-only`) stalled
production issuance, because `mgryn.cc`'s negative-TTL SOA (1800s) had
those resolvers still caching `NODATA` after the record went live, and
that flag meant no other opinion counted. Debug a failed issuance against
`letsencrypt-staging` first — production allows only 5 failed validations
per hostname per hour.

## Related

README.md "TLS"; [#16](https://github.com/maxim-grin/homelab/pull/16)-[#21](https://github.com/maxim-grin/homelab/pull/21),
especially [#20](https://github.com/maxim-grin/homelab/pull/20) "fix: check
DNS-01 against authoritative servers"; CLAUDE.md "`jobs.mgryn.cc`'s
certificate comes from cert-manager".
