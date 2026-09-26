# Operations

Everything here assumes a fresh account in `ap-south-1`. Commands are written to be pasted as-is; the ones that touch AWS are marked, and none of them were executed as part of building this repository — only the offline verification commands were.

---

## Prerequisites

- **Terraform** >= 1.10 (`terraform/versions.tf`) and an AWS provider in the 5.x series; the committed `.terraform.lock.hcl` pins `hashicorp/aws 5.100.0`.
- **AWS credentials** for the target account, and permission to create VPCs, IAM roles, ACM certificates (or DNS validation), EC2 instances, ECS, ECR, WAFv2, KMS, DynamoDB, CloudWatch, Config, Security Hub, Route 53 and Budgets.
- **A real domain** with a Route 53 hosted zone, plus the ability to create the ACM validation records. The example values ship as `example.com` (`terraform/terraform.tfvars.example`).
- **A GitHub repository** that this account can read, with `main` as the default branch — the Jenkins controller fetches its own configuration from `main` at boot (`jenkins/casc/jenkins.yaml:5`).
- **Node >= 22** if you intend to run the app or the local quality gate (`app/package.json`).
- **A GPG-capable committer** if you want signed tags, because the pipeline refuses unsigned ones by default (`Jenkinsfile:216`).

---

## Bootstrap order

The order is not stylistic; each step depends on the previous one existing.

### 1. Push the JCasC file first — before any apply

```bash
git push origin main      # must include jenkins/casc/jenkins.yaml
```

The controller fetches `https://raw.githubusercontent.com/<owner>/<repo>/main/jenkins/casc/jenkins.yaml` at boot, in `EXCLUSIVE` mode. If that file is missing or malformed, the controller **does not start**. This is the single most common way to get stuck.

### 2. Create the state bucket (optional, but do it before step 3)

```bash
cp terraform/bootstrap/terraform.tfvars.example terraform/bootstrap/terraform.tfvars
# edit region + bucket_name
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap apply
```

This is a separate root module on purpose: the module whose state a bucket holds cannot also create that bucket (`terraform/backend.tf:14`). It creates the bucket with versioning, SSE-KMS on a dedicated CMK, public access fully blocked, a TLS-only policy, and a 90-day noncurrent-version lifecycle rule. Note the CMK ARN it prints — you need it in step 3.

### 3. Move the root module onto S3 (optional)

Uncomment the `backend "s3"` block in `terraform/backend.tf`, set `kms_key_id` to the ARN from step 2, then:

```bash
terraform -chdir=terraform init -migrate-state
```

S3 native locking (`use_lockfile = true`, Terraform >= 1.10) replaces the old DynamoDB lock table. If you skip this step the state stays local, which is fine for one operator and unsafe for two.

### 4. Plan and apply the stack

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
terraform -chdir=terraform init
terraform -chdir=terraform plan
terraform -chdir=terraform apply
```

Notes:

- `github_repo` defaults to `rishabh-yadav11/flowharbor-jenkins` (`terraform/variables.tf:139`); override it if you forked.
- `cloudfront_origin_verify_token` is **required** when `enable_cloudfront = true` and must be at least 32 characters. Generate with `openssl rand -hex 32` and pass it as `TF_VAR_cloudfront_origin_verify_token`, never in a committed tfvars.
- `enable_cloudfront` defaults to `false` (`terraform/variables.tf:60`). Leave it false for a first apply: the edge ACL is in `us-east-1` and the origin-verify guard only exists when the distribution does.
- `budget_alert_emails` defaults to `[]`, which means the budget exists and reports but notifies nobody. That is deliberate — add your own address.
- `jenkins_allowed_ipv4_cidrs` gates the Jenkins host at the WAF. If you set it to a range you are not actually behind, you will lock yourself out; see the failure-modes table.
- The Jenkins instances have `user_data_replace_on_change = true` (`terraform/modules/jenkins-master/main.tf:50`), so a change to the bootstrap script replaces the controller on the next apply.

### 5. Watch the first boot

```bash
aws ssm get-parameter --name /flowharbor/jenkins-master-ready
```

The bootstrap writes the admin password, the master URL, and this ready marker into Parameter Store, then prints `MASTER_SETUP_COMPLETE` to the console (`terraform/user-data/jenkins-master.sh:407`). CloudWatch-init needs a few minutes; `terraform output jenkins_url` gives the controller URL, and `terraform output jenkins_admin_password_command` gives the command that prints the admin password.

---

## Deploy runbook

A release is always a semver tag, always promoted forward, never rebuilt downstream.

```bash
# 1. Cut the tag on the commit you want to ship
git tag -a 1.4.0 -m "release 1.4.0"
git push origin 1.4.0
```

Then, in Jenkins:

| # | Job | Parameters | What it does |
| --- | --- | --- | --- |
| 1 | `flowharbor-dev` | `GIT_TAG=1.4.0`, `REBUILD=true` | Builds the image, pushes it, scans it, deploys it. The only job that can produce an image. |
| 2 | `flowharbor-staging` | `GIT_TAG=1.4.0`, `REBUILD=false` | Resolves the digest dev already pushed, re-asserts the scan, deploys. |
| 3 | `flowharbor-prod` | `GIT_TAG=1.4.0`, `REBUILD=false` | Same, plus the manual approval, plus the check that prod's digest equals staging's. |

`REBUILD` defaults to `true` for dev and `false` for staging and prod (`terraform/user-data/flowharbor-jobs.groovy:33`). If a tag commit is not GPG-signed the run stops; set `ALLOW_UNSIGNED_TAGS=true` to override deliberately, and expect the override in the audit trail.

What each stage does, in order: `Checkout Tag` → `Verify` (lint, typecheck, coverage, SBOM) → `Build` → `Push to ECR` → `Resolve Release` → `Approval` (prod only) → `Deploy`. The full sequence is drawn in [architecture.md](architecture.md#3-release-sequence).

---

## Rollback runbook

**Option 1 — redeploy the previous tag (preferred, use this):**

```bash
git tag -a 1.3.9 -m "redeploy 1.3.9"    # only if the tag does not already exist
```

Then run `flowharbor-dev` → `flowharbor-staging` → `flowharbor-prod` with `GIT_TAG=1.3.9`. Downgrades below the currently running version are refused (`Jenkinsfile:611`), so if prod is on 1.4.0 and you need to go back to 1.3.9 you will hit that gate — roll forward by deploying a fixed 1.4.1 instead, or use option 2.

**Option 2 — repoint the service by hand (the escape hatch):**

```bash
aws ecs update-service \
  --cluster flowharbor-cluster \
  --service flowharbor-prod \
  --task-definition <family>:<revision>
```

This is exactly the command the pipeline's automatic rollback runs when `post { failure }` finds a deploy that was armed (`Jenkinsfile:496`), and the log tells you the exact `--task-definition` value to use if the automatic attempt fails (`Jenkinsfile:502`). Find the revisions with:

```bash
aws ecs list-task-definitions --family-prefix flowharbor --status ACTIVE --sort DESC
```

**Automatic rollback** covers the common case: if `update-service` or the `services-stable` wait fails, the pipeline repoints the service to the revision it captured before the update and waits again (`Jenkinsfile:489`). It is armed only immediately before the service update, so a failure in an earlier gate leaves the running service untouched.

**What rollback does not undo:** rows written to DynamoDB. A bad release that created todos leaves them behind; a task-definition rollback is not a data rollback (`terraform/modules/dynamodb/main.tf:37`).

---

## Jenkins recovery

**Controller will not start / jobs are missing.** Almost always the JCasC file: confirm it is on `main` and parses, then restart the service and watch the log for the configuration import.

```bash
sudo systemctl restart jenkins
sudo journalctl -u jenkins -f | grep -i "configuration import"
```

A malformed or unreachable `jenkins.yaml` aborts the boot by design (`jenkins/casc/jenkins.yaml:39`, `EXCLUSIVE` mode) — the alternative is a controller running with a default policy, which is worse. After boot the bootstrap's own check re-runs on the next instance replacement; to verify manually:

```bash
for e in dev staging prod; do
  curl -s -o /dev/null -w "%{http_code}\n" -u "admin:$ADMIN_PASS" \
    "http://localhost:8080/job/flowharbor-$e/api/json"
done
```

**Credentials are gone (rebuilt controller).** The two Jenkins string credentials are created by the bootstrap after the controller is up (`terraform/user-data/jenkins-master.sh:373`, `terraform/user-data/jenkins-master.sh:383`). Recreate them through the Jenkins UI, or force an instance replacement with `terraform apply -replace=module.jenkins_master.aws_instance.this`.

**Agent will not connect.** The agent waits for the `/flowharbor/jenkins-master-ready` marker before downloading `agent.jar` and connecting over JNLP (`terraform/user-data/jenkins-master.sh:400`). On the agent, `journalctl -u` (or the serial console) shows whether it is still waiting or failed to connect; the usual causes are an expired instance profile, a security group change, or the controller's `remotingSecurity` rejecting an unauthenticated agent. The marker is also a quick check:

```bash
aws ssm get-parameter --name /flowharbor/jenkins-master-ready
```

---

## State recovery

The state bucket is versioned, so a corrupted or accidentally-applied state is recoverable.

```bash
# 1. See the versions
aws s3api list-object-versions \
  --bucket flowharbor-terraform-state \
  --prefix flowharbor/terraform.tfstate

# 2. Restore a known-good version
aws s3api get-object \
  --bucket flowharbor-terraform-state \
  --key flowharbor/terraform.tfstate \
  --version-id <version-id> restored.tfstate

# 3. Put it back
aws s3api copy-object \
  --bucket flowharbor-terraform-state \
  --key flowharbor/terraform.tfstate \
  --copy-source "flowharbor-terraform-state/flowharbor/terraform.tfstate?versionId=<version-id>"

terraform -chdir=terraform state pull > /tmp/state-before.tfstate
```

Noncurrent versions expire after 90 days (`terraform/bootstrap/main.tf:120`), so recovery is a 90-day window, not forever.

**Losing state entirely** is recoverable in a different way: with no state, Terraform will try to *create* everything and fail on name collisions, or worse, adopt nothing and plan replacements. Recover the state file first; do not run `apply` against a lost state. If state is genuinely unrecoverable, treat it as a rebuild: import or destroy in dependency order (VPC and endpoints first, then compute) rather than applying the whole stack blind.

**Stuck lock.** S3 native locking stores its lock object in the bucket; a crashed run can leave one behind. Confirm no run is active, then remove the lock object and re-run.

---

## Failure modes

Each row is a real gate in `Jenkinsfile`; the grep line is the literal text the pipeline emits, so you can search a build log for it directly.

| Gate | Log line to grep | What it means | The fix |
| --- | --- | --- | --- |
| Environment allowlist | `REFUSING to deploy: invalid TARGET_ENV` | The job name suffix is not `dev`/`staging`/`prod` | You started a job outside the three names; use `flowharbor-<env>` (`Jenkinsfile:186`) |
| Missing tag | `GIT_TAG parameter is required` | The build was started with an empty `GIT_TAG` | Re-run with the tag, e.g. `1.4.0` (`Jenkinsfile:189`) |
| Bad semver | `is invalid. Use semver format` | The tag is not `X.Y.Z` | Use a semver tag; create one if the repo does not have it (`Jenkinsfile:200`) |
| Tag does not resolve | `Cannot resolve tag` | The tag is not in the repo, or was never pushed | `git push origin <tag>` (`Jenkinsfile:207`) |
| Unsigned tag | `Unsigned tag/commit` | The commit is not GPG-signed and `ALLOW_UNSIGNED_TAGS` is false | Sign the commit and move the tag, or set `ALLOW_UNSIGNED_TAGS=true` deliberately (`Jenkinsfile:216`) |
| Quality gate | `npm ERR!` / a Vitest failure / an ESLint finding | Lint, typecheck, or a test failed in `Verify` | Fix locally: `cd app && npm run lint && npm run typecheck && npm run test:coverage` (`Jenkinsfile:249`) |
| High-severity dependency | `npm audit` finding at high | `npm audit --audit-level=high` failed in `Build` | Update the dependency; the Dependabot PR is the usual route (`Jenkinsfile:281`) |
| ECR repo validation | `REFUSING ECR op:` | The `ECR_REPOSITORY` credential is malformed or points somewhere unexpected | Re-store the credential from `terraform output ecr_repository_url` (`Jenkinsfile:42`, `Jenkinsfile:46`) |
| ECR scan never completes | `ECR scan did not reach COMPLETE` | After 5 minutes the scan is still pending | Usually a large image or a scan queue backlog. Re-run; if it repeats, check scan status manually with `aws ecr describe-image-scan-findings` (`Jenkinsfile:100`) |
| ECR scan response is incomplete | `ECR scan returned no findingSeverityCounts` | The scan finished but the response had no severity counts — treated as unknown, not as clean | Re-run the scan or check the image manually; do not disable the gate (`Jenkinsfile:112`) |
| ECR scan found CRITICAL | `ECR scan found` | The image has at least one CRITICAL finding | Rebuild with patched dependencies; an override here is a real risk acceptance (`Jenkinsfile:116`) |
| Digest not resolvable after push | `Failed to resolve digest` | The push succeeded but the digest could not be read back | Re-run; check `aws ecr describe-images` for the tag (`Jenkinsfile:318`) |
| Local/remote digest mismatch | `Digest mismatch: local RepoDigests` | The pushed image is not the one just built | Treat as a serious signal — do not retry blindly; inspect the ECR repository (`Jenkinsfile:325`) |
| Promotion without a dev build | `No image for tag` | `REBUILD=false` but no image exists for that tag | Run `flowharbor-dev` with `REBUILD=true` first (`Jenkinsfile:374`) |
| Malformed promoted digest | `malformed digest` | The digest from ECR did not match `sha256:[0-9a-f]{64}` | Investigate the ECR repository; do not force a deploy (`Jenkinsfile:377`) |
| Production approval | `Abort` / the `input` waiting on screen | Waiting for a release manager, or nobody is one | Press Proceed as `release-managers`/`admin`, or create those accounts; the stage times out after 30 minutes (`Jenkinsfile:403`) |
| Deployment blocked by chain or downgrade | `Promotion chain violated` | Prod's image is not the one staging is running | Deploy to staging first, with the same tag (`Jenkinsfile:595`) |
| Downgrade refused | `REFUSING downgrade` | The requested version is lower than what is running | Roll forward to a fixed version, or use the `update-service --task-definition` escape hatch (`Jenkinsfile:611`) |
| Deploy by mutable tag | `REFUSING to deploy by mutable tag` | Something passed a `:tag` instead of `@sha256:` | A bug in the pipeline or a hand-edited task definition; the deploy must be digest-pinned (`Jenkinsfile:581`) |
| Hardening lost on a new revision | `ASSERT:` | The registered task definition lost a property (digest pin, `user=node`, read-only rootfs, health check, mounts, or a secret) | Fix the ECS module; the assert exists so this cannot ship silently (`Jenkinsfile:741`) |
| Service never stabilises | `Waiter ServiceStable failed` | Tasks are not reaching a steady state after the update | Read the service events: `aws ecs describe-services --cluster flowharbor-cluster --services flowharbor-prod`; check the task stopped reason in CloudWatch under `/ecs/flowharbor-prod`. The pipeline attempts the rollback itself |
| Rollback itself failed | `ROLLBACK FAILED` | The automatic repoint did not stabilise the service | Run the command the log prints, by hand, against the named revision (`Jenkinsfile:502`) |
| Terraform lock/state error (infrastructure) | `Error acquiring the state lock` | A concurrent apply, or a lock left by a crashed run | Confirm nothing is running, then remove the lock object from the state bucket and re-run |
| Trivy misconfiguration finding (PR) | the Trivy action's finding output | A HIGH/CRITICAL IaC finding | Fix it, or add a one-line justified entry to `.trivyignore` — never lower `severity` or set `exit-code: "0"` (`.github/workflows/terraform.yml:53`) |
| WAF lockout of the Jenkins UI | HTTP 403 from the WAF on `jenkins.<domain>` | Your IP is not in `jenkins_allowed_ipv4_cidrs`, or the rate limit tripped | Widen `jenkins_allowed_ipv4_cidrs` in tfvars and apply. If you are fully locked out, the practical escape is to reach the controller over SSM Session Manager and edit the allowlist — there is no in-console bypass |
