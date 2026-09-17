# Security Policy

## Supported Versions

| Component | Supported |
| --------- | --------- |
| `main` branch / latest git tag (semver `X.Y.Z`) | ✅ |
| Older tags | ❌ (upgrade to latest tag) |
| `next` | `15.5.24`+ (14.x is EOL for known RCEs, see Dependabot) |

## Reporting a Vulnerability

Use GitHub **Private vulnerability reporting** (Security tab → Report a vulnerability).
Do not open a public issue for sensitive reports.

Include: affected tag/commit, reproduction steps, impact, and suggested fix if known.

We aim to acknowledge within 72 hours.

## Scope Notes

- Deploys are tag-based via Jenkins (`GIT_TAG` semver, digest-pinned, staging→prod promotion chain). Only signed tags on `refs/tags/*` are accepted for release (repository ruleset `protect-release-tags`).
- `main` is protected by ruleset `protect-main-min` (no deletion, no force-push, required signatures).
- Secret scanning + push protection are enabled. Never commit `.env`, `*.pem`, `terraform.tfvars`, or `*.tfstate`.
