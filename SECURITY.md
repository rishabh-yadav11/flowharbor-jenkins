# Security Policy

This repository ships a delivery path (Jenkins → ECR → ECS Fargate) and the
Terraform that provisions it. This document describes what the pipeline and the
infrastructure actually enforce, where that enforcement lives in source, what
it deliberately does not cover, and how to report a problem.

Every control below is cited to a file and line in this repository. A control
that cannot be pointed at is not listed as one.

---

## 1. Supported versions

| Component | Supported | Source of truth |
|---|---|---|
| `main` / latest semver tag | yes | releases are cut by tagging; a deployable tag must match the semver pattern at `Jenkinsfile:199` |
| Older tags | no — redeploy the newest tag | — |
| `next` | `16.3.5` (exact pin, not a range) | `app/package.json:27` |
| `react` / `react-dom` | `^19.3.0` | `app/package.json:28` |
| `typescript` | `5.9.3` | `app/package.json:51` |
| Node.js | `>=22`; CI matrix runs 22 and 24 | `app/package.json:17`, `.github/workflows/ci.yml` |
| Terraform | `>= 1.10`; `hashicorp/aws` `>= 5.0, < 6.0`, locked to `5.100.0` | `terraform/versions.tf`, `terraform/.terraform.lock.hcl` |
| Container base image | `node:26.8-alpine` digest-pinned in both build stages | `app/Dockerfile:1`, `app/Dockerfile:10` |
| Jenkins controller | WAR `2.568.1` | `terraform/user-data/jenkins-master.sh:97` |

The app is pinned, not floated. `next` is an exact version, so a security fix
arrives as a deliberate Dependabot PR (`.github/dependabot.yml`, npm ecosystem)
rather than as an unattended change to a running build. The base image is
pinned by digest, so even a re-pushed upstream tag cannot change what a build
produces without a visible Dockerfile edit.

---

## 2. What the delivery pipeline enforces

Each row is present in source at the cited line. The gates have **not** been
executed against a live AWS account, and this document does not claim
otherwise. What has been verified is that the `Jenkinsfile` parses under
Jenkins' own declarative validator and that the logic reads as documented.

### 2.1 Release provenance

| Control | Enforced at | Behaviour |
|---|---|---|
| Environment allowlist | `Jenkinsfile:185`, `Jenkinsfile:536` | `TARGET_ENV` is derived from the job name, not a parameter (`Jenkinsfile:168`); anything outside `dev`/`staging`/`prod` is refused, and `promote()` re-checks |
| Semver format | `Jenkinsfile:199` | `GIT_TAG` must match a strict semver pattern before it is interpolated into any shell command, so a tag value cannot inject shell or JavaScript |
| Tag → immutable commit | `Jenkinsfile:205`, `Jenkinsfile:206` | The tag resolves to a 40-hex SHA and the checkout is asserted to be at that SHA |
| Signed tag/commit | `Jenkinsfile:212`, `Jenkinsfile:216` | An unsigned or unverifiable commit **fails the build** unless `ALLOW_UNSIGNED_TAGS=true` |
| Author sanitisation | `Jenkinsfile:232`, `Jenkinsfile:233` | `git log --format=%an` is attacker-controlled; newlines are stripped (log spoofing), remaining characters allowlisted, result truncated to 32 |
| Workspace hygiene | `Jenkinsfile:221` | `git clean -fdx` before checkout, so no stale artifact reaches a build |
| ECR repository allowlist | `Jenkinsfile:39`, `Jenkinsfile:41` | The registry URL is regex-validated before any `docker login`, so a poisoned credential cannot exfiltrate to a foreign registry |
| Temp file shredding | `Jenkinsfile:722` | The task-definition payload is `shred -u`'d in a `finally` block, best-effort, and its result never lets a deploy proceed |

### 2.2 Build and artifact integrity

| Control | Enforced at | Behaviour |
|---|---|---|
| Quality gates before any build | `Jenkinsfile:249` | `npm ci --ignore-scripts` + lint + typecheck + coverage; a failure here stops the run before a single image layer exists |
| Dependency audit | `Jenkinsfile:281`, `app/Dockerfile:6` | `npm audit --audit-level=high` fails the build, in CI and again in the image build |
| Provenance signatures | `app/Dockerfile:5` | `npm audit signatures` verifies registry signatures during the image build |
| SBOM per release | `Jenkinsfile:254` | CycloneDX 1.6, dev dependencies omitted, archived and fingerprinted as a build artifact |
| No `:latest` | `Jenkinsfile:287` | The image is tagged with the git tag only |
| Digest cross-check | `Jenkinsfile:313`, `Jenkinsfile:324` | The digest returned by ECR must appear in the local `RepoDigests`, so a push that landed something other than what was built fails the run |
| ECR immutability | `terraform/modules/ecr/main.tf:22` | `IMMUTABLE` tag mutability: a tag cannot be overwritten after it is pushed |

### 2.3 The image-scan gate

`assertImageScanned` (`Jenkinsfile:81`) is the most important fail-closed path
in the repository, and it runs on **both** the build path and the promotion
path:

| Requirement | Enforced at | Behaviour |
|---|---|---|
| Scan must complete | `Jenkinsfile:99` | Ten attempts at 30 s. An image whose scan never reaches `COMPLETE` is refused, not assumed clean |
| Findings must be present | `Jenkinsfile:111` | A response with no `findingSeverityCounts` key at all is an **error**, never "zero findings" |
| Zero CRITICAL | `Jenkinsfile:114`, `Jenkinsfile:116` | Any CRITICAL count fails the build |
| Re-gated on promotion | `Jenkinsfile:387` | The promotion path pushed nothing, so it calls the same gate independently — a promotion cannot skip the scan |

`scan_on_push` is enabled at `terraform/modules/ecr/main.tf:27`, so the scan
starts on push rather than waiting for the pipeline to ask.

There is no `|| true` anywhere on this path. Across the whole `Jenkinsfile`,
`grep -c '|| true'` returns exactly `3`: a comment at `Jenkinsfile:79` that
records the fail-open wait this gate replaced, the signature probe at
`Jenkinsfile:212` (which only captures the verifier's output — the gate itself
is the `error` at `Jenkinsfile:216`), and the best-effort `shred` at
`Jenkinsfile:722`.

### 2.4 Promotion and deploy safety

| Control | Enforced at | Behaviour |
|---|---|---|
| Digest pin required | `Jenkinsfile:580` | Deploying by mutable tag is refused outright |
| Staging → prod chain | `Jenkinsfile:594` | Prod may only deploy the image the staging task definition is already running; a mismatch fails |
| Downgrade guard | `Jenkinsfile:610` | The running version may never decrease. A silent rollback that reintroduces a CVE fails closed |
| No-op guard | `Jenkinsfile:614` | An identical image is not redeployed, preventing deploy churn |
| Hardening preserved across deploys | `Jenkinsfile:630`, `Jenkinsfile:677` | The pipeline mutates the **current** container definition in place, swapping only the image and non-secret env, so Terraform-owned hardening is not dropped on every deploy |
| Secrets never in plaintext | `Jenkinsfile:656`, `Jenkinsfile:683` | `GIT_AUTHOR` and `PIPELINE_URL` are published as SSM `SecureString` and delivered through the ECS `secrets` block; any pre-existing plaintext entry with those names is dropped |
| Post-registration asserts | `Jenkinsfile:741`–`Jenkinsfile:748` | Eight assertions on the **registered** revision: digest pin, `user == node`, `readonlyRootFilesystem`, `healthCheck`, `/tmp` mount, `/app/public` mount, both secrets present, both absent from `environment` |
| Automatic rollback | `Jenkinsfile:628`, `Jenkinsfile:759`, `Jenkinsfile:489` | The previous task-definition revision is captured, the rollback is armed immediately before `update-service`, and a failure restores the prior revision and waits for `services-stable` again |
| Bounded waits | `Jenkinsfile:772`, `Jenkinsfile:130` | `services-stable` is capped at 10 minutes and the whole build at 20, so a stuck deployment cannot pin an executor |
| Deploy notifications | `Jenkinsfile:470`, `Jenkinsfile:509` | SUCCESS and FAILURE are published to the KMS-encrypted alerts topic, guarded and `returnStatus` so a missing topic can never turn a green deploy red |

### 2.5 The one override

`ALLOW_UNSIGNED_TAGS=true` is the only documented way to deploy a tag whose
commit is not GPG-signed.

- **What it is for:** cutting an unsigned release when the signing key is
  temporarily unavailable, or when a release is cut from a commit signed with a
  key the build agent does not trust.
- **It is never the default.** The parameter defaults to `false` in the Job DSL
  (`terraform/user-data/flowharbor-jobs.groovy:34`) and in the pipeline
  (`Jenkinsfile:144`).
- **It is logged.** When the override takes effect the build prints
  `ALLOW_UNSIGNED_TAGS=true: deploying unsigned tag by explicit operator
  override.` (`Jenkinsfile:218`), on top of the signature-verification output
  itself (`Jenkinsfile:213`). An override is visible in the build log.
- **It is per-invocation.** It is a job parameter, not persisted configuration,
  so approving one run does not weaken the next.

---

## 3. What the infrastructure enforces

### 3.1 Access control

| Control | Where | Detail |
|---|---|---|
| Controller runs no builds | `jenkins/casc/jenkins.yaml:43` | `numExecutors: 0`. Every job pins `agent { label 'jenkins-slave' }` (`Jenkinsfile:123`), so building on the controller is impossible rather than discouraged |
| Matrix authorization | `jenkins/casc/jenkins.yaml:51` | `matrix-auth` Global Matrix. `anonymous` gets `Overall/Read` only; `developer` and `release-managers` additionally get `Job/Read` + `Job/Build`; the admin gets `Overall/Administer` |
| Remoting channel | `jenkins/casc/jenkins.yaml:73` | `remotingSecurity` is enabled, so the agent↔controller channel is not open to unauthenticated peers |
| Signup disabled | `jenkins/casc/jenkins.yaml:46` | `allowsSignup: false` |
| JCasC is fail-closed | `jenkins/casc/jenkins.yaml:39` | `mode: EXCLUSIVE` — a malformed policy file aborts the controller boot rather than silently degrading to a weaker default |
| Bootstrap asserts its own work | `terraform/user-data/jenkins-master.sh:347` | The bootstrap verifies all three jobs exist and exits non-zero otherwise, so a half-applied controller cannot serve a weakened policy |
| Production approval | `Jenkinsfile:400`, `Jenkinsfile:406` | The `Approval` stage runs only for `prod` and names `release-managers,admin` as the accounts allowed to proceed. The submitter list is a list of accounts, not a permission; reachability is governed by the matrix |
| Separate CI and workload identities | `terraform/modules/iam/main.tf:555` | The ECS task role and the Jenkins agent role are distinct. The controller running no builds means a workload compromise does not yield the CI credentials |
| Scoped task permissions | `terraform/modules/iam/main.tf:555` | Seven DynamoDB item actions scoped to the todo table and its indexes — no table-wide or account-wide grants |
| Scoped notification grant | `terraform/modules/iam/main.tf:372` | `sns:Publish` on the single alerts topic, not `*` |
| Scoped secret writes | `terraform/modules/iam/main.tf:356` | `ssm:PutParameter` for the agent is scoped to the `/flowharbor/*` path rather than granted globally |
| Security groups by tier | `terraform/modules/security-groups/main.tf` | Separate groups for ALB, controller, agent, and tasks, with the task group egress-only toward the data tier |
| WAF allowlist on Jenkins | `terraform/modules/waf/main.tf` | The Jenkins host rule is restricted by an IPv4 allowlist and rate-limited on `/login`; `jenkins_allowed_ipv4_cidrs` defaults to `[]`, i.e. deny-all (`terraform/variables.tf:106`) |

### 3.2 Encryption, data protection, and audit

| Control | Where | Detail |
|---|---|---|
| KMS CMK for logs | `terraform/modules/observability-logging/main.tf:9` | Central customer-managed key, so log access is auditable through CloudTrail |
| Encrypted alerts topic | `terraform/modules/observability-logging/main.tf:25` | The SNS topic uses the same CMK |
| Encrypted todo table | `terraform/modules/dynamodb/main.tf` | SSE-KMS on `flowharbor-todos`, with point-in-time recovery and deletion protection enabled |
| Scan on push | `terraform/modules/ecr/main.tf:27` | `scan_on_push = true` |
| WAF request logging | `terraform/modules/waf/main.tf:252`, `terraform/modules/waf/main.tf:266` | 30-day log group with `authorization` and `cookie` redacted, so request logs are not themselves a credential store |
| CloudWatch alarms | `terraform/modules/monitoring/main.tf` | Seven alarms across ECS CPU/memory, ALB 5xx/latency/unhealthy hosts, WAF blocks, and controller reachability, all with `alarm_actions`/`ok_actions` and `treat_missing_data = "notBreaching"` |
| Drift and posture | `terraform/modules/governance/main.tf` | AWS Config recorder and delivery, three ADVISORY managed rules, and Security Hub subscribed to the Foundational Security Best Practices standard |
| Response headers | `app/next.config.js:4`, `app/next.config.js:19` | HSTS with preload, a restrictive CSP, `X-Frame-Options: DENY`, `nosniff`, `Referrer-Policy`, and a `Permissions-Policy` disabling camera, microphone, geolocation, and browsing-topics |

### 3.3 Container hardening

Terraform sets it on every service and the pipeline asserts it survived:

| Property | Terraform | Assertion |
|---|---|---|
| Runs as non-root `node` | `terraform/modules/ecs/main.tf:45` | `Jenkinsfile:742` |
| Read-only root filesystem | `terraform/modules/ecs/main.tf:46` | `Jenkinsfile:743` |
| Never privileged | `terraform/modules/ecs/main.tf:47` | — (asserted by construction in Terraform) |
| Container health check | `terraform/modules/ecs/main.tf:51` | `Jenkinsfile:744` |
| Writable `/tmp` and `/app/public` only | `app/entrypoint.sh:6` | `Jenkinsfile:745`, `Jenkinsfile:746` |
| Unprivileged port 3000 | `app/Dockerfile:14`, `app/Dockerfile:22` | — |
| Digest-pinned base image | `app/Dockerfile:1`, `app/Dockerfile:10` | — |

---

## 4. What the application itself does

The app is a small, honest Next.js todo list. Its input handling is real, and
tested:

| Control | Where | Detail |
|---|---|---|
| Title validation | `app/src/lib/todos/validate.ts:12`, `app/src/lib/todos/validate.ts:15` | 120-character cap and control-character rejection |
| Id validation | `app/src/lib/todos/validate.ts:3` | Strict `^[A-Za-z0-9-]{1,64}$` before any repository call |
| Every action validates | `app/src/app/todos/actions.ts:9`, `:21`, `:34` | `createTodo`, `toggleTodo`, and `deleteTodo` each parse their input first |
| Runtime-config escaping | `app/entrypoint.sh:36`, `app/src/lib/runtime-config.ts:26` | Boot config is serialized with `JSON.stringify` and `<`, `>`, U+2028, and U+2029 escaped, so `</script>` cannot break out of an inline script |
| Runtime-config URL safety | `app/entrypoint.sh:24`, `app/src/lib/runtime-config.ts:34` | URLs are parsed with `new URL`, restricted to `http:`/`https:`, and control characters rejected — a `javascript:` value degrades to `"#"` |
| Runtime-config size cap | `app/entrypoint.sh:51`, `app/src/lib/runtime-config.ts:19` | 8192-byte ceiling on the generated file, enforced on both the shell and TypeScript sides |
| Conditional put | `app/src/lib/todos/dynamodb.ts` | A create uses a condition expression, so a create cannot overwrite an existing row |
| Health endpoint | `app/src/app/api/health/route.ts:8`, `:33` | 2-second database timeout, returns 200 or 503, `Cache-Control: no-store` |

The escaping contract is not asserted by inspection — it is tested by running
the real `entrypoint.sh` as a program in a temp directory
(`app/tests/entrypoint.test.ts`), with `RUNTIME_CONFIG_DIR`
(`app/entrypoint.sh:15`) and `FLOWHARBOR_SKIP_EXEC=1`
(`app/entrypoint.sh:57`) making that possible.

Two design decisions make the XSS surface small rather than merely guarded:

- **The config is loaded as an external file, never inlined.**
  `app/src/app/layout.tsx:24` emits `<script src="/runtime-config.js" defer />`,
  so a hostile `VERSION` or `GIT_AUTHOR` is never parsed as part of an HTML
  document. The escaping above is the second line of defence, not the first.
- **The committed file is an inert placeholder.** `app/public/runtime-config.js`
  ships with `__ENV__`-style literal placeholders and is overwritten at container
  boot (`app/entrypoint.sh:52`). A local `npm run dev` therefore renders
  placeholders rather than any real value.

The CSP is correspondingly tight: `script-src 'self' 'unsafe-inline'` with no
`unsafe-eval` and no remote origins (`app/next.config.js:22`). There is no
`dangerouslySetInnerHTML` anywhere in `app/src`, so no value reaches the DOM as
markup by any other route.

---

## 5. Repository-level scanning

| Control | Where | Detail |
|---|---|---|
| CI on pull requests | `.github/workflows/ci.yml` | Lint, typecheck, and the enforced coverage gate on Node 22 and 24; `permissions: contents: read` |
| CodeQL | `.github/workflows/codeql.yml` | `security-extended` query suite for JavaScript/TypeScript on push, pull request, and a weekly cron |
| IaC misconfiguration scan | `.github/workflows/terraform.yml` | `trivy config` at `severity: HIGH,CRITICAL` with `exit-code: "1"`, re-run when `.trivyignore` changes so a suppression cannot be widened silently |
| Terraform fmt/validate | `.github/workflows/terraform.yml` | `fmt -check -recursive`, then `init -backend=false` and `validate` so CI never needs AWS credentials |
| Dependency updates | `.github/dependabot.yml` | Four ecosystems (npm in two groups, docker, github-actions, terraform), weekly |
| Suppressions on the record | `.trivyignore` | Two check ids, each with a written justification. Severity and `exit-code` stay strict: an empty ignore file still fails the scan |

**Honest limit of the suppression file.** A bare id in `.trivyignore`
suppresses that check *everywhere*, including occurrences that do not exist yet.
`AWS-0053` and `AWS-0104` are justified for this architecture, but a human has
to notice that the justification no longer holds. That is a real weakness of
id-based suppression, and no configuration of this tool removes it.

---

## 6. Operator must confirm: repository settings

None of the following live in this repository. They are GitHub account
settings, and this repo cannot prove them. Check them yourself before relying
on them.

- [ ] **Branch protection for `main`** — `Settings → Branches → Branch
  protection rules` (or `Settings → Rules → Rulesets`): require pull requests,
  require status checks `verify (node 22)` and `verify (node 24)`, require
  linear history, block force pushes and branch deletion.
- [ ] **Tag ruleset** — `Settings → Rules → Rulesets`, a ruleset targeting
  `refs/tags/*`: restrict creation, update, and deletion, and require signed
  commits. The pipeline's signature gate is the backstop, not the substitute
  (`Jenkinsfile:216`).
- [ ] **Secret scanning** — `Settings → Code security → Secret scanning`:
  enabled.
- [ ] **Secret scanning push protection** — `Settings → Code security → Secret
  protection → Push protection`, set to **Block**.
- [ ] **Dependabot alerts** — `Settings → Code security → Dependabot alerts`:
  enabled, so the configured Dependabot PRs are not the only signal.
- [ ] **Code scanning** — `Settings → Code security → Code scanning`:
  enabled, and confirm the CodeQL workflow (`.github/workflows/codeql.yml`)
  reports into it.
- [ ] **Default branch and merge rules** — `Settings → General → Pull
  Requests`: squash-merge only, delete head branches on merge.
- [ ] **Two-factor authentication and least-privilege membership** —
  `Settings → Authentication security` (require 2FA) and `Organization →
  People` (no outside collaborators on this repo).
- [ ] **Actions permissions** — `Settings → Actions → General`: consider
  restricting `GITHUB_TOKEN` to read-only by default. All three workflows
  already declare `permissions: contents: read`; the CodeQL job additionally
  needs `security-events: write` and already requests it.
- [ ] **Jenkins is not publicly reachable** — `jenkins_allowed_ipv4_cidrs`
  defaults to `[]`, i.e. deny-all (`terraform/variables.tf:106`). Populate it
  with real operator CIDRs, or you lock yourself out of your own controller.

---

## 7. Known accepted gaps

These are decisions, not oversights. Each is recorded so nobody reads the
control tables above as a complete picture.

### The app has no authentication or authorization

The todo application has **no authentication, no authorization, and no per-user
data model**. Anyone who can reach the deployed endpoint can read, create,
complete, and delete todos, and the list is global.

This is deliberate. The security surface this repository demonstrates is the
**delivery path and the edge** — WAF allowlist, digest-pinned promotion, scoped
IAM, KMS encryption, fail-closed gates, automatic rollback — not the
application's own access control. Adding a demo login would produce a *worse*
artifact: an authentication system that looks real but is not, sitting in front
of a genuine security posture.

**Do not deploy this app as-is for anything containing real user data.** Adding
authentication is separate work: an identity source, an authorization check and
ownership predicate on all three server actions, an owner key in the repository
interface and in the DynamoDB item, session handling in the runtime-config
contract, and CSRF protection. `docs/threat-model.md` scopes that in full.

### Other accepted gaps

- **No image signing or provenance attestation.** ECR immutability plus digest
  pinning plus a CycloneDX SBOM is what is implemented. cosign/Sigstore and SLSA
  provenance need a KMS key or an OIDC trust exchange that cannot be exercised
  here.
- **No EDR or runtime threat detection on the Fargate tasks.** ECS Exec is
  enabled on all three services for operator access
  (`terraform/modules/ecs/main.tf:308`), which is a debugging capability and
  also an attack surface.
- **Task egress is not restricted** beyond what the NAT gateways provide.
- **Egress allowlist suppressions are broad.** `AWS-0104` is suppressed by id;
  see the limit described in section 5.
- **Multi-tenancy does not exist.** The DynamoDB table is single-tenant by
  construction.

### Known defect: CloudFront log delivery would be denied

This is a bug, not a design choice, and it is recorded here rather than fixed
because it only manifests when `enable_cloudfront = true` — the default is
`false`, so it cannot be observed without an AWS account.

The CloudFront distribution configures standard access logging to the shared log
bucket (`terraform/modules/cloudfront/main.tf:104`). The bucket policy grants
`s3:PutObject` to `logdelivery.elasticloadbalancing.amazonaws.com` and
`delivery.logs.amazonaws.com` only
(`terraform/modules/observability-logging/main.tf:77`). There is **no statement
for `cloudfront.amazonaws.com`**, so CloudFront would be denied on `PutObject`
and access logs would silently never arrive.

The comment immediately above that policy claims to "Allow ALB + VPC flow +
CloudFront log delivery" (`terraform/modules/observability-logging/main.tf:76`),
so the code contradicts its own stated intent. Fixing it means adding a
`cloudfront.amazonaws.com` statement conditioned on
`aws:SourceAccount` and `aws:SourceArn`, matching the VPC flow-log statement
above it. Anyone enabling the CDN should treat it as a required prerequisite.

---

## 8. Reporting a vulnerability

Use **GitHub private vulnerability reporting**, not a public issue:

- Repository → `Security` tab → `Report a vulnerability`, or
  <https://github.com/rishabh-yadav11/flowharbor-jenkins/security/advisories/new>

Please include: the affected tag or commit SHA, reproduction steps, the impact
you observed, and a suggested fix if you have one. Do not open a public issue, a
pull request, or a discussion for a report you have not yet confirmed as safe
to disclose.

Non-code security issues — GitHub repository settings, DNS, ACM, the live
endpoints, or a running AWS account — are out of scope for this repository's
source and belong with the account owner.

---

## 9. What not to commit

- `.env` and any `*.pem` or other key material
- `terraform/terraform.tfvars` — gitignored at `.gitignore:8`
- `*.tfstate`, `*.tfstate.backup`, and `.terraform/` — gitignored at
  `.gitignore:1`–`.gitignore:2`

Two ignore entries are deliberate and should not be "cleaned up":

- **`.terraform.lock.hcl` is committed** (see the note at `.gitignore:4`).
  Without the lock file, two people can plan the same code against different
  provider versions and get different plans.
- **`coverage/`, `.next/`, and `node_modules/` are ignored** (`.gitignore:11`–`.gitignore:13`).
