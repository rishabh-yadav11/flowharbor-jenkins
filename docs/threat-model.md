# Threat model

Scope: this repository, its pipeline, and the AWS account it configures. This is an engineer's model of what the code actually defends against — not a claim of certification, and not a penetration test. Every mitigation below points at a line in the repo; anything I could not find a line for is in the "Not covered" section at the end.

---

## Assets

| Asset | Why it matters | Where it lives |
| --- | --- | --- |
| The container image (digest) | The only thing that becomes running code; immutability of its tag is what makes staging and prod identical | ECR, `terraform/modules/ecr/main.tf:20` |
| Release provenance | Which commit, which human, which tag produced the running image | `Jenkinsfile:182` stage 1, task-definition secrets |
| AWS credentials in CI | Whoever holds the agent role can register task definitions, push images, and publish alerts | `terraform/modules/iam/main.tf:165` (slave role) |
| The Jenkins controller's admin account | Full control of the controller, and through it of every job | `jenkins/casc/jenkins.yaml:48` |
| Container secrets (`GIT_AUTHOR`, `PIPELINE_URL`) | Injected as `SecureString`; must never appear in plaintext task-def environment | `terraform/modules/ecs/main.tf:96` |
| Log and audit data | WAF decisions, VPC flow logs, ECS task output | `terraform/modules/observability-logging/main.tf:30` |
| Terraform state | Defines every resource above | `terraform/backend.tf:50` (local by default) |
| The todo data | The app's only mutable state; a bad release can write rows that a task-def rollback does not undo | `terraform/modules/dynamodb/main.tf:19` |

---

## Trust boundaries

**TB-1 — Internet → edge.** Anything reaching the WAF is hostile by default. The controls are an IPv4 allowlist plus rate limits on the Jenkins host, and the AWS managed rule groups on everything. The Jenkins controller is deliberately *not* fronted by a security group that only trusts the office network; it is fronted by an L7 rule, because the same ALB also serves three public environments.

**TB-2 — Edge → origin workload.** TLS terminates at the ALB. When CloudFront is enabled, the production host rule additionally requires a secret header that only the distribution sends, so an origin-direct request for the production hostname lands on the 404 default (`terraform/modules/alb/main.tf:266`). This is a bypass guard, not authentication.

**TB-3 — Workload → data, and workload → CI.** The ECS task reaches exactly one table with seven actions and nothing else (`terraform/modules/iam/main.tf:555`). The Jenkins agent role is a separate identity from the task role, and the controller itself runs no builds (`jenkins/casc/jenkins.yaml:43`), so a compromise of the application workload does not yield a path to the CI credentials.

---

## Actors

| Actor | Capability | What they can reach |
| --- | --- | --- |
| **Anonymous internet** | Unauthenticated HTTP to any of the four host rules | Public app surfaces; the Jenkins login page, which is rate-limited and IP-allowlisted |
| **Authenticated developer** | Jenkins `developer` matrix entry: `Overall/Read`, `Job/Read`, `Job/Build` (`jenkins/casc/jenkins.yaml:58`) | Can start `flowharbor-dev` and promote a tag to dev/staging — and prod, if they also hold a release-manager account |
| **Release manager** | Same plus the ability to press Proceed on the production `input` (`Jenkinsfile:406`) | The only account class that can complete a production deploy |
| **Compromised dependency** | Runs inside `npm ci`, the build, and the SBOM generation | Build-time code execution on the agent; caught downstream by the Trivy misconfig scan, `npm audit --audit-level=high` (`Jenkinsfile:281`), and the ECR image scan |
| **Compromised CI host** | The agent, or the controller | Agent role: build, push, deploy, publish. Controller: everything, plus every stored credential |

---

## Threats and mitigations

| Threat class | Mitigation | Anchor |
| --- | --- | --- |
| Tag or commit not attributable to a release | Semver format, resolution to a commit SHA, and a GPG signature check that refuses to deploy an unsigned commit unless explicitly overridden | `Jenkinsfile:200`, `Jenkinsfile:207`, `Jenkinsfile:216` |
| A mutable tag lets prod and staging diverge | ECR tag immutability plus a refusal to deploy by mutable tag | `terraform/modules/ecr/main.tf:22`, `Jenkinsfile:581` |
| Staging promoted to prod without being the tested artifact | Promotion-chain check comparing the prod image against the running staging image | `Jenkinsfile:595` |
| Version rollback as an attack (or as an accident) | Downgrade refusal — the running version may never decrease | `Jenkinsfile:611` |
| A vulnerable or unscanned image reaching production | `assertImageScanned` polls until `COMPLETE`, treats a missing `findingSeverityCounts` as unknown rather than clean, and fails on any CRITICAL — and runs on the promotion path too, which pushed nothing | `Jenkinsfile:100`, `Jenkinsfile:112`, `Jenkinsfile:116`, `Jenkinsfile:387` |
| Unreviewed infrastructure changes | GitHub Actions: `fmt -check`, `validate` with no backend, and a Trivy misconfig scan failing on HIGH/CRITICAL | `.github/workflows/terraform.yml:44`, `.github/workflows/terraform.yml:48`, `.github/workflows/terraform.yml:67` |
| Supply-chain drift | Dependabot across npm, Docker, GitHub Actions and Terraform, weekly, grouped | `.github/dependabot.yml:3`, `.github/dependabot.yml:32` |
| A malicious PoC or branch name breaking out of the runtime-config `<script>` | Values are JSON-escaped with `<`/`>`/U+2028/U+2029 escaped, capped in length, and URLs restricted to `http:`/`https:` — the config is loaded as an external file, never inlined | `app/entrypoint.sh:36`, `app/src/lib/runtime-config.ts:34`, `app/src/app/layout.tsx:20` |
| Hostile input reaching the app's own data layer | Title length and control-character validation, id pattern validation, and a conditional put so a create cannot overwrite an existing row | `app/src/lib/todos/validate.ts:13`, `app/src/lib/todos/validate.ts:23`, `app/src/lib/todos/dynamodb.ts:71` |
| Internet access to the Jenkins controller | WAF IP allowlist on the Jenkins host plus two rate limits, instead of an open security group | `terraform/modules/waf/main.tf:62`, `terraform/modules/waf/main.tf:111`, `terraform/modules/waf/main.tf:134` |
| WAF decisions being unusable after the fact | Request logging to a 30-day log group with `authorization` and `cookie` redacted | `terraform/modules/waf/main.tf:252`, `terraform/modules/waf/main.tf:268` |
| Secrets leaking into the task definition's plaintext environment | Secrets delivered through the ECS `secrets` block, and a post-register assertion that fails the deploy if either name appears in `environment` | `terraform/modules/ecs/main.tf:169`, `Jenkinsfile:748` |
| A redeploy silently dropping container hardening | Eight post-register assertions on the *registered* revision: digest-pinned image, `user=node`, read-only rootfs, health check, both mounts, secrets present, secrets absent from environment | `Jenkinsfile:741`, `Jenkinsfile:742`, `Jenkinsfile:743`, `Jenkinsfile:748` |
| A bad deploy left in place | Automatic repoint to the previously captured task-definition revision, armed only immediately before `update-service` | `Jenkinsfile:628`, `Jenkinsfile:759`, `Jenkinsfile:489` |
| Anyone with matrix access starting a production build | `numExecutors: 0` on the controller, matrix entries that give `Job/Build` to named groups, and a production `input` naming the accounts allowed to proceed | `jenkins/casc/jenkins.yaml:43`, `jenkins/casc/jenkins.yaml:58`, `Jenkinsfile:406` |
| A half-applied controller silently serving a weakened policy | The bootstrap asserts all three jobs exist and exits non-zero otherwise; JCasC runs in `EXCLUSIVE` mode | `terraform/user-data/jenkins-master.sh:347`, `jenkins/casc/jenkins.yaml:39` |
| Data at rest readable outside the account | KMS CMKs for logs, the todo table, and the state bucket; the alerts topic uses the same CMK | `terraform/modules/observability-logging/main.tf:9`, `terraform/modules/dynamodb/main.tf:31`, `terraform/bootstrap/main.tf:97` |
| A release's outcome being invisible | The pipeline publishes SUCCESS/FAILURE to the encrypted SNS topic, guarded and `returnStatus` so a missing topic can never turn a green deploy red | `Jenkinsfile:470`, `Jenkinsfile:509` |
| Cost running away | A monthly COST budget with an 80% notification, defaulting to no subscriber rather than a hardcoded address | `terraform/main.tf:125`, `terraform/main.tf:137` |
| No visibility into a bad release at runtime | One dashboard and seven alarms on ECS CPU/memory, ALB 5xx/latency/unhealthy hosts, WAF blocked requests, and controller reachability — all published to the alert topic | `terraform/modules/monitoring/main.tf:36`, `terraform/modules/monitoring/outputs.tf:19` |
| Undetected configuration drift | AWS Config recorder with all supported resource types, three ADVISORY managed rules, and Security Hub subscribed to the Foundational Security Best Practices standard | `terraform/modules/governance/main.tf:151`, `terraform/modules/governance/main.tf:183`, `terraform/modules/governance/main.tf:226` |

---

## The application has no authentication — and that is a decision, not an oversight

**The todo app has no authentication, no authorisation, and no per-user data model.** Anyone who can reach the public host can create, toggle, and delete todos, and the list is global. There is no session, no identity provider, and no ownership check in the server actions (`app/src/app/todos/actions.ts:9`).

This is accepted here for a specific reason: the security story this artifact is demonstrating lives at the **edge and in the delivery path**, not in the application. The interesting, reviewable properties are the WAF allowlist, the digest-pinned promotion, the scoped IAM, the KMS encryption, the fail-closed gates, and the rollback — none of which an auth layer would strengthen, and several of which a demo auth layer would obscure. Adding a fake login would also create a *worse* artifact: an authentication system that looks real but is not, sitting in front of a genuine security posture.

What adding authentication would have to cover, for anyone extending this:

- An identity source (OIDC against a real IdP is the obvious choice; a local credential store would be a regression).
- Authorisation on every server action, not just in the UI — `createTodo`, `toggleTodo` and `deleteTodo` would each need a session check and an ownership predicate, and the repository interface would need an owner key rather than a bare `id` (`app/src/lib/todos/repository.ts:6`).
- A data model change in DynamoDB: ownership in the item, and queries scoped by it instead of a full `Scan` (`app/src/lib/todos/dynamodb.ts:39`).
- Session handling in the runtime config contract, which currently ships a frozen global object with no per-user state (`app/entrypoint.sh:47`).
- CSRF protection on the server actions, and a change to the `input` submitter model in the pipeline if approvals should follow identity.
- Tests for the authorisation boundary itself — the current suite tests validation, not access control.

---

## Configuration as code is fail-closed, and that has a cost

`jenkins/casc/jenkins.yaml` is applied at `EXCLUSIVE` mode: a malformed file, or a fetch failure because the file is not on the default branch yet, **aborts the controller boot rather than degrading to a default configuration.** This was observed directly while building this repo.

The implication is worth stating plainly: the RBAC model in git is the RBAC model in the running controller, with no fallback path where a partially-applied policy quietly grants someone too much. The cost is an ordering constraint that an operator must respect — push the file before the first apply — and a controller that will not come up at all if that file is malformed. For a system where "is the security policy applied?" is the question that matters, failing to boot is the correct failure, and it is asserted rather than assumed: the bootstrap checks that all three jobs exist afterwards and exits non-zero if any is missing (`terraform/user-data/jenkins-master.sh:347`).

---

## Not covered

These are outside what this repository can defend, and are stated so nobody reads the table above as a complete picture:

- **No app-level auth, rate limiting, or abuse control** beyond the WAF rules described above.
- **No multi-tenancy** in DynamoDB; the table is single-tenant by construction.
- **No image signing or provenance attestation.** ECR immutability plus digest pinning is what is implemented; cosign/Sigstore and SLSA provenance need a KMS key or an OIDC trust exchange that cannot be exercised here.
- **No EDR or runtime threat detection on the Fargate tasks.** ECS Exec is enabled on all three services for operator access (`terraform/modules/ecs/main.tf:308`), which is a debugging capability and also an attack surface.
- **Egress is not restricted** from the tasks beyond what the NAT gateways provide.
- **Repository settings are not in source**: branch protection, secret scanning, and push protection are GitHub account settings, and this repo cannot assert them.
- **Nothing here has been tested against a live account.** Every anchor was verified by reading the file or by running the project's own local checks; no AWS API response is claimed anywhere in this document.
