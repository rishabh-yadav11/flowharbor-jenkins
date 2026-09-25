# Security Policy

## Supported versions

| Component | Supported | Source of truth |
|---|---|---|
| `main` / the latest semver tag | yes | releases are cut by tagging; see `Jenkinsfile:199` for what a deployable tag must look like |
| Older tags | no — redeploy the newest tag | — |
| `next` | `16.3.5` (exact pin) | `app/package.json:27` |
| `react` | `^19.3.0` | `app/package.json:28` |
| `typescript` | `5.9.3` | `app/package.json:51` |
| Node.js | `>=22` (CI matrix 22 and 24) | `app/package.json:17`, `.github/workflows/ci.yml` |
| Terraform | `>= 1.10`; `hashicorp/aws` `>= 5.0, < 6.0`, locked to `5.100.0` | `terraform/versions.tf` |
| Container base image (`node:26.8-alpine`) | digest-pinned in both build stages | `app/Dockerfile:1`, `app/Dockerfile:10` |

The app is pinned, not floated: the `next` version is an exact pin, so a security
fix arrives as a deliberate Dependabot PR (`.github/dependabot.yml`, npm ecosystem)
rather than as an automatic change to a running build.

## What the pipeline enforces by default

Every row below is present in source at the cited line. A reviewer who runs the
Jenkinsfile through `POST /pipeline-model-converter/validate` on a local controller
knows the file parses; the gates themselves have not been executed against a real
AWS account, and this repo does not claim otherwise.

| Control | Enforced at | Default behaviour |
|---|---|---|
| Signed-tag requirement | `Jenkinsfile:216` | An unsigned tag or commit **fails the build**. `ALLOW_UNSIGNED_TAGS` defaults to `false` in the job parameter (`Jenkinsfile:144`, `terraform/user-data/flowharbor-jobs.groovy:34`) |
| Dependency audit | `Jenkinsfile:281` | `npm audit --audit-level=high` fails the build |
| Quality gates on the agent | `Jenkinsfile:246` | lint, typecheck, and enforced coverage thresholds run before anything is built |
| Digest pinning | `Jenkinsfile:580`, `Jenkinsfile:741` | A deploy must reference `repo@sha256:…`; a mutable tag is rejected, and the registered task definition is re-asserted as digest-pinned |
| ECR scan gating | `Jenkinsfile:100`, `Jenkinsfile:112`, `Jenkinsfile:116` | The scan must reach `COMPLETE`, must return a `findingSeverityCounts` key, and must report `0` CRITICAL findings. An absent key is treated as a failure, not a pass |
| Staging promotion chain | `Jenkinsfile:595` | Production can only deploy an image already running in staging |
| Semver downgrade guard | `Jenkinsfile:611` | An older version over a newer one fails closed |
| Production approval | `Jenkinsfile:401`, `Jenkinsfile:406` | `input` restricted to `release-managers,admin`; the stage only runs for `prod` |
| Container hardening asserts | `Jenkinsfile:741`–`Jenkinsfile:748` | 8 post-registration asserts: `user == node`, `readonlyRootFilesystem`, `healthCheck`, `/tmp` and `/app/public` mounts, and `GIT_AUTHOR`/`PIPELINE_URL` present as task secrets and **absent** from `environment` |
| Automatic rollback | `Jenkinsfile:489` | A failed deploy restores the previous task-definition revision and waits for `services-stable` again |
| Deployment notifications | `Jenkinsfile:470`, `Jenkinsfile:509` | Outcome published to the KMS-encrypted alerts topic (`terraform/modules/observability-logging/main.tf:25`) |
| Controller RBAC | `jenkins/casc/jenkins.yaml:51` | `matrix-auth` Global Matrix: anonymous gets `Overall/Read` only; `developer` and `release-managers` additionally get `Job/Build`; admin gets `Overall/Administer`. Verified locally: anonymous `POST /job/flowharbor-dev/build` returns `403` |
| No builds on the controller | `jenkins/casc/jenkins.yaml:43` | `numExecutors: 0`; every job pins `agent { label 'jenkins-slave' }` (`Jenkinsfile:123`) |
| Remoting channel | `jenkins/casc/jenkins.yaml:73` | `remotingSecurity` enabled, so the agent↔controller channel is not open to unauthenticated peers |
| IAM scoping | `terraform/modules/iam/main.tf:372`, `terraform/modules/iam/main.tf:555` | `sns:Publish` on the one alerts topic; DynamoDB item actions scoped to the todo table and its indexes |
| KMS-encrypted logs and alerts | `terraform/modules/observability-logging/main.tf:9`, `terraform/modules/observability-logging/main.tf:25` | Central log CMK, and the SNS topic encrypted with it |
| WAF request logging | `terraform/modules/waf/main.tf:248`, `terraform/modules/waf/main.tf:262` | 30-day log group, `authorization` and `cookie` redacted so request logs are not a credential store |
| CloudWatch alarms | `terraform/modules/monitoring/main.tf:279` | 7 alarms publish to the alerts topic, with `treat_missing_data = "notBreaching"` |
| Governance | `terraform/modules/governance/main.tf:224` | AWS Config recorder and delivery, 3 ADVISORY managed rules, Security Hub with the Foundational standard |
| Response headers | `app/next.config.js:4`, `app/next.config.js:19` | HSTS and a Content-Security-Policy on every response |
| Runtime config escaping | `app/entrypoint.sh:36`, `app/entrypoint.sh:51` | Boot-generated `runtime-config.js` escapes `<`, `>`, U+2028 and U+2029 and is size-capped; the escaping contract is covered by `app/tests/entrypoint.test.ts` |
| IaC scanning | `.github/workflows/terraform.yml` | Trivy `misconfig` at `severity: HIGH,CRITICAL` with `exit-code: "1"`; suppressions live in `.trivyignore`, one justified entry per line |
| Dependency updates | `.github/dependabot.yml` | 4 ecosystems, weekly, including terraform providers |

## The one override

`ALLOW_UNSIGNED_TAGS=true` is the only documented way to deploy a tag whose commit
is not GPG-signed.

- **What it is for:** cutting an unsigned release when the signing key is
  temporarily unavailable, or when a release is cut from a commit that was signed
  with a key the build agent does not trust.
- **It is never the default.** The parameter defaults to `false` in the Job DSL
  (`terraform/user-data/flowharbor-jobs.groovy:34`) and in the pipeline
  (`Jenkinsfile:144`).
- **It is logged.** When the override takes effect the build prints
  `ALLOW_UNSIGNED_TAGS=true: deploying unsigned tag by explicit operator override.`
  (`Jenkinsfile:218`), on top of the signature-verification output itself
  (`Jenkinsfile:213`). An override is visible in the build log, not silent.
- **It is per-invocation.** It is a job parameter, not persisted configuration, so
  approving one run does not weaken the next.

## Operator must confirm: repository settings

None of the following live in this repository. They are GitHub account settings and
this repo cannot prove them. Check them yourself before relying on them.

- [ ] **Branch protection for `main`** — `Settings → Branches → Branch protection rules` (or `Settings → Rules → Rulesets`): require pull requests, require status checks `verify (node 22)` and `verify (node 24)`, require linear history, block force pushes and branch deletion.
- [ ] **Tag ruleset** — `Settings → Rules → Rulesets` → create a ruleset targeting `refs/tags/*`: restrict creation/update/deletion, and require signed commits. The pipeline's signature gate is the backstop, not the substitute (`Jenkinsfile:216`).
- [ ] **Secret scanning** — `Settings → Code security → Secret scanning`: enabled, with `Push protection` set to **Block**.
- [ ] **Secret scanning push protection** — `Settings → Code security → Secret protection → Push protection`.
- [ ] **Dependabot alerts** — `Settings → Code security → Dependabot alerts`: enabled, so `.github/dependabot.yml` PRs are not the only signal.
- [ ] **Code scanning** — `Settings → Code security → Code scanning`: enabled, and confirm the CodeQL workflow (`.github/workflows/codeql.yml`) reports to it.
- [ ] **Default branch and merge rules** — `Settings → General → Pull Requests`: squash-merge only, and delete head branches on merge.
- [ ] **Two-factor authentication and least-privilege membership** — `Settings → Authentication security` (require 2FA) and `Organization → People` (no outside collaborators on this repo).
- [ ] **Jenkins is not publicly reachable** — `jenkins_allowed_ipv4_cidrs` defaults to `[]`, i.e. deny-all (`terraform/variables.tf:106`). Populate it with real operator CIDRs, or you lock yourself out of your own controller.

## Known accepted gap

The todo application has **no authentication and no authorization**. Anyone who can
reach the deployed endpoint can read, create, complete, and delete todos. This is
deliberate for the case study — the security surface being demonstrated is the
delivery path and the edge, not the application's own access control — and it is
recorded as an accepted gap rather than an oversight. Do not deploy this app as-is for
anything containing real user data; adding authentication is a separate piece of work,
scoped in the threat model ([`docs/threat-model.md`](docs/threat-model.md)).

## Reporting a vulnerability

Use **GitHub private vulnerability reporting**, not a public issue:

- Repository → `Security` tab → `Report a vulnerability`, or
  `https://github.com/rishabh-yadav11/flowharbor-jenkins/security/advisories/new`

Please include: the affected tag or commit SHA, reproduction steps, the impact you
observed, and a suggested fix if you have one. Do not open a public issue, a pull
request, or a discussion for a report you have not yet confirmed as safe to disclose.

Non-code security issues — GitHub repository settings, DNS, ACM, the live
endpoints, or a running AWS account — are out of scope for this repository's source
and belong with the account owner.

## What not to commit

`.env`, `*.pem` and other key material, `terraform/terraform.tfvars` (gitignored via
`.gitignore:8`), and `*.tfstate` / `.terraform/` state. The Terraform provider lock
file is deliberately committed (`.gitignore:4`) for reproducibility, and `coverage/`
is ignored.
