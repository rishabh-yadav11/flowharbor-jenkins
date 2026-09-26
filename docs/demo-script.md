# Demo script — five minutes

A walkthrough for someone reviewing this repository. The point is not to show a running website; it is to show that the claims are checkable in about two minutes of terminal time, and that the delivery path fails closed.

Everything below runs on a clean checkout with **no AWS account, no Docker, and no Jenkins controller**.

---

## Part 1 — three commands, with what they should print

### 1. The quality gate

```bash
cd app && npm ci --ignore-scripts && npm run lint && npm run typecheck && npm run test:coverage
```

`--ignore-scripts` is deliberate — it is what the CI workflow uses (`.github/workflows/ci.yml:37`), and a clean checkout passes with it, so no dependency install script is part of the trust story.

**What you should see:** lint and typecheck print nothing; the coverage run reports **11 test files / 77 tests passing**, with the configured thresholds satisfied — the global 70/70/70/60 and the stricter `src/lib/**` 90/90/90/85 (`app/vitest.config.ts:31`, `app/vitest.config.ts:36`) — and exits 0. In the most recent full run the global figures were 88.33% statements, 86.93% branches, 97.5% functions.

**The question this answers:** is the pipeline carrying something real, or an untested shell? Here it carries a gate that runs lint, types, and 77 tests with a coverage floor that fails the build if it is not met.

### 2. The infrastructure gate

```bash
terraform -chdir=terraform init -backend=false -input=false && \
terraform -chdir=terraform fmt -check -recursive && \
terraform -chdir=terraform validate
```

**What you should see:** `fmt` prints nothing (it is `-check`; any output is a failure), and `validate` ends with `Success! The configuration is valid.`

`-backend=false` is what makes this work with no credentials — the S3 backend block is commented out on purpose so a clone can validate the whole stack offline (`terraform/backend.tf:7`).

**The question this answers:** is the infrastructure real, and does a reviewer need an AWS account to check it? The stack is 16 modules of real resources; `terraform plan` is deliberately *not* part of this check because the availability-zone data source needs credentials, and the runbook documents that limitation instead of pretending around it.

### 3. The app, running locally

```bash
npm run build && (npm start &) && sleep 5
curl -i http://localhost:3000/api/health
curl -s http://localhost:3000/ | grep -o 'data-done=' | wc -l
```

**What you should see:** `HTTP/1.1 200` with `Cache-Control: no-store`, and a body containing `"status":"ok"`, `"env":"dev"`, and a `checks.database` block. The second command prints **3** — the three seeded todos are rendered server-side.

The `curl` command must use `grep -o ... | wc -l`. `grep -c` counts matching *lines*, and the built HTML is minified onto one line, so `grep -c` prints `1` no matter how many rows are present. That is a property of the formatter, not of the app.

**The question this answers:** does the container image the pipeline deploy have something real in it, with a health endpoint the pipeline and the load balancer can both use? It does — and the health endpoint answers 503 with `"status":"degraded"` when the data layer is misconfigured (`app/src/app/api/health/route.ts:32`).

---

## Part 2 — four things to look at

### `Jenkinsfile` — "what stops a bad image from reaching production?"

Grep for `error "` and read the messages. There are three fail-closed gates that are easy to miss because they are written as ordinary lines:

- **The signature gate** (`Jenkinsfile:216`) refuses to deploy an unsigned commit unless someone explicitly overrides it.
- **The scan gate** (`Jenkinsfile:100`, `:112`, `:116`) polls ECR until the scan is `COMPLETE`, treats a response with no `findingSeverityCounts` as *unknown rather than clean*, and fails on any CRITICAL finding. It also runs on the *promotion* path (`Jenkinsfile:387`), which never pushed an image and so has no excuse for skipping it.
- **The deploy gate** (`Jenkinsfile:581`) refuses to deploy by mutable tag, and `Jenkinsfile:741` re-asserts the digest pin, the non-root user, the read-only root filesystem, the health check, and the secret handling against the task definition ECS actually accepted — not against the one Terraform wrote.

Then look at the promotion path: `Build` and `Push to ECR` run only when `REBUILD=true` (`Jenkinsfile:267`), and `Resolve Release` runs only when it is false (`Jenkinsfile:353`). Dev builds; staging and prod deploy the digest dev already built.

**Also worth showing:** the rollback. `promote()` records the running revision before touching anything (`Jenkinsfile:628`) and arms a flag immediately before the service update (`Jenkinsfile:759`), and `post { failure }` uses that flag to repoint the service if the deploy did not stabilise (`Jenkinsfile:489`).

### `terraform/main.tf` — "how is the provider policy, and what does the module graph actually connect?"

Three things:

- The root wires 16 modules, and two of those wires are the ones that make the data layer real: the DynamoDB table name goes to both the ECS task definition (`TODO_TABLE`) and the task role's IAM policy. Read `module "dynamodb"`, `module "iam"`, and `module "ecs"` together.
- The edge WAF ACL is genuinely wired to the distribution now — the origin guard is not decorative. `web_acl_id` is set from the edge ACL when CloudFront is enabled (`terraform/main.tf:354`), and that ACL is in `us-east-1` because WAFv2 rejects a regional ACL at a distribution (`terraform/modules/waf/main.tf:289`).
- `default_tags` is set at the provider level (`terraform/main.tf:39`), not per resource, so nothing can forget to be attributed.

### `app/src/lib/` — "is the payload a real application, or a shell?"

Read these three files, in this order:

- `repository.ts` — the backend switch. `DATA_BACKEND=dynamodb` selects the real store; anything else (local dev, tests) uses an in-memory one, so the app runs with zero AWS access (`app/src/lib/todos/repository.ts:22`).
- `memory.ts` — three seeded todos, newest-first ordering, with the round-trip and unknown-id semantics the tests assert.
- `runtime-config.ts` — the escaping contract. `serializeRuntimeConfig` escapes `<` and `>` so a hostile value cannot break out of the `<script>` tag that carries it (`app/src/lib/runtime-config.ts:26`); `safeUrl` returns `null` for a `javascript:` URL (`app/src/lib/runtime-config.ts:34`); `parseRuntimeConfig` rejects an oversize payload (`app/src/lib/runtime-config.ts:63`).

**Why this matters to the pipeline:** that config file is generated at container boot, not baked into the image (`app/entrypoint.sh:52`), which is exactly what lets one immutable digest serve as dev, staging, and prod.

### `jenkins/casc/jenkins.yaml` — "is the access control real, or a comment?"

It is a real file, applied at `EXCLUSIVE` mode. Read:

- `numExecutors: 0` (`jenkins/casc/jenkins.yaml:43`) — the controller runs no builds; every job pins the agent label.
- the `globalMatrix` entries (`jenkins/casc/jenkins.yaml:51`) — anonymous gets read-only, `developer` and `release-managers` get read and build, and nobody else gets anything.
- `jobs: - file:` (`jenkins/casc/jenkins.yaml:84`) — the three jobs are created from a file at import time, which is what makes them exist on a controller that cannot run a seed job.

**The consequence to state out loud:** because it is `EXCLUSIVE`, a malformed or unreachable JCasC file aborts the controller boot rather than falling back to a default policy. That is the right failure — but it means the file must be on the default branch before the first `terraform apply`, which is the first step in the runbook.

---

## If you have five more minutes

- Read one ADR: [0002](adr/0002-immutable-ecr-digest-pinned-deploys.md) (immutable ECR) and [0007](adr/0007-policy-as-code-not-bootstrap-script.md) (policy as code) are the two most load-bearing.
- Open the [failure-modes table](operations.md#failure-modes) and pick any row — each one is a literal string the pipeline emits, so you can grep a build log for it.
- Read the [threat model](threat-model.md#the-application-has-no-authentication--and-that-is-a-decision-not-an-oversight) and its "not covered" list, which is the part most demos leave out.
