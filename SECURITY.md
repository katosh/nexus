# Security Policy

## Reporting a vulnerability

**Do not open a public issue for security vulnerabilities.**

Use GitHub's [private vulnerability reporting](https://github.com/<your-org>/nexus-code/security/advisories/new)
to submit a report. This keeps the details confidential until a fix
is available.

Please include:

- A minimal reproducer or step-by-step trace.
- The commit SHA (or tagged version) you reproduced against.
- The expected vs observed behaviour.
- Your assessment of impact and a suggested mitigation if you have
  one.

## Scope

A vulnerability is anything that lets the bot:

- Post or react as the configured user (eligibility filter bypass).
- Read or write a GitHub repository the App is not installed on.
- Escape the agent-sandbox directory it runs inside.
- Leak the App's RSA private key off the watcher host.
- Mutate the audit trail (`monitor/.state/action-log.jsonl`,
  `watcher.log`, `watcher-alerts.log`) silently.

Out of scope (accepted trade-offs):

- Network exfiltration by an agent. Agents need outbound network for
  the Anthropic API; isolation is not currently in scope.
- A malicious GitHub App owner. The App owner is the trust root.
- Anything requiring shell access to the watcher host — that's
  game-over by construction.

For the full threat model, authorization tiers, and compromise
response, see [`docs/admin/security.md`](docs/admin/security.md).

## Response expectations

- **Acknowledgment** within 1 week. Best-effort; the project is
  hobbyist-scale.
- **Triage** as soon as practical.
- **Coordinated disclosure** with the reporter. If the issue cannot
  be fixed quickly, it is documented as a known limitation with
  mitigations.

## Supported versions

Only `main` is supported. Please reproduce against the current commit
before reporting.
