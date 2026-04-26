# Security policy

## Reporting a vulnerability

Please **do not** open a public GitHub issue for a security concern. Email
the maintainer directly: woblavobla@gmail.com (PGP not currently published).

Include:

- Description of the vulnerability and its impact
- A reproducer (Hyperion config, sample request, expected vs actual behaviour)
- The Hyperion version you tested against

You should receive an acknowledgement within 7 days. Disclosure timeline is
coordinated with you; default is 30 days from acknowledgement to public
disclosure once a fix is shipped.

## In-scope

- Request smuggling / response splitting
- Memory/FD/connection leaks under adversarial input
- TLS/ALPN downgrade or misconfiguration
- Logger or metrics paths leaking sensitive data
- Crashes/panics from malformed HTTP/1.1 or HTTP/2 traffic

## Out of scope

- Vulnerabilities in upstream dependencies (`async`, `protocol-http2`, `rack`,
  `llhttp`) — please report to the upstream project.
- Vulnerabilities in user-supplied Rack apps.
- Denial of service via lawful traffic volume (use a rate limiter / WAF).
