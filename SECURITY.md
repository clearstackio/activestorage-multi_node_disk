# Security policy

## Reporting a vulnerability

Report it privately through
[GitHub's private vulnerability reporting](https://github.com/clearstackio/activestorage-multi_node_disk/security/advisories/new),
or email ajaya@clearstack.io. Please do not open a public issue.

We aim to acknowledge a report within three working days, and to publish a
fix and a GitHub security advisory once it is confirmed.

Include the activestorage-multi_node_disk version (or commit), how to
reproduce the problem, and what an attacker could read or delete.

## Supported versions

activestorage-multi_node_disk is pre-1.0. Only the latest release is
supported.

## The model

- The node endpoint checks **who is calling** (`auth`), never who may see a
  file: that stays with the host app. The default, `:none`, checks nothing;
  use `:token` (or `[:ip, :token]`) anywhere but a closed network.
- Tokens are compared in constant time, never logged and never part of an
  event or audit entry. Under `:token`, node URLs must be HTTPS.
- `:ip` trusts `X-Forwarded-For` only from proxies the app lists in
  `config.action_dispatch.trusted_proxies`; otherwise the socket's peer counts.
- A requester sent by another node is recorded as verified only after a check
  passed. It must never carry a secret.
- Releases are published to rubygems.org from GitHub Actions with trusted
  publishing (no long-lived API key) and carry a Sigstore attestation. Any
  other push needs MFA (`rubygems_mfa_required`).
