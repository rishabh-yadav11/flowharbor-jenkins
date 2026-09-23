// =============================================================================
// Jenkinsfile — FlowHarbor CI/CD Pipeline (Tag-Based, Per-Environment)
// =============================================================================
// This declarative Jenkins pipeline builds and deploys the FlowHarbor demo
// application for a SINGLE environment, selected by the Jenkins job that runs it.
//
// Jobs:
//   flowharbor-dev      → deploys to dev      (https://testing.flowharbor.in)
//   flowharbor-staging  → deploys to staging  (https://staging.flowharbor.in)
//   flowharbor-prod     → deploys to prod     (https://flowharbor.in)
//
// Trigger: MANUAL only. No SCM polling, no webhooks. A developer runs one of the
// three jobs and enters the GIT_TAG parameter (the git tag to build and deploy).
//
// Pipeline stages (in order):
//   1. Checkout Tag   — validate env + tag, resolve tag to immutable SHA, verify,
//      clean workspace and check out the SHA (Jenkinsfile itself from main).
//   2. Verify         — npm ci, lint, typecheck, enforced coverage gate, and a
//      CycloneDX SBOM archived as the supply-chain artifact.
//   3. Build          — Docker image build, tagged with GIT_TAG only (no :latest)
//   4. Push to ECR    — Push tag, resolve + verify digest, scan gate, archive metadata
//   5. Resolve Release— (REBUILD=false) resolve the digest dev already built, re-gate
//   6. Approval       — manual prod gate, release-managers/admin only
//   7. Deploy         — Register new TD revision pinned to repo@digest and roll env.
//
// Stages 3-4 run only when REBUILD=true (dev). Staging and prod run with
// REBUILD=false and promote the exact digest dev built, so staging and prod
// can never ship a different image than the one that was scanned and verified.
// On success, a summary banner with the deployed environment, tag and digest is printed.
//
// The `promote()` function encapsulates the logic for registering a new ECS
// task definition revision and triggering a rolling service update.
// =============================================================================

// ---- Shared helpers (issue #20 hardening) -----------------------------------
// Validate ECR URL against a strict allowlist and return the repository path
// (supports namespaced team/app). Fail closed to block token exfiltration to
// a foreign registry via a poisoned credential.
def ecrRepoName(String url) {
    def v = (url ?: '').trim()
    if (!(v ==~ /^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com(\.cn)?\/[a-z0-9]+(?:[._\/-][a-z0-9]+)*$/)) {
        error "REFUSING ECR op: invalid ECR_REPOSITORY '${v.take(80)}'"
    }
    def parts = v.tokenize('/')
    if (parts.size() < 2) {
        error "REFUSING ECR op: no repository path in '${v.take(80)}'"
    }
    return parts.drop(1).join('/')
}

// Fixed-width box cell: truncate then pad so banner borders never misalign.
def box(String s, int n) {
    return (s ?: '').take(n).padRight(n)
}

// Semver compare: -1 / 0 / 1. Non-semver values sort below valid releases.
def compareSemver(String a, String b) {
    def parse = { String v ->
        def m = (v?.trim() ?: '') =~ /^([0-9]+)\.([0-9]+)\.([0-9]+)(?:-([0-9A-Za-z.-]+))?(?:\+.*)?$/
        if (!m.find()) return null
        return [m.group(1).toInteger(), m.group(2).toInteger(), m.group(3).toInteger(), m.group(4) ?: '']
    }
    def pa = parse(a)
    def pb = parse(b)
    if (pa == null && pb == null) return 0
    if (pa == null) return -1
    if (pb == null) return 1
    for (int i = 0; i < 3; i++) {
        if (pa[i] != pb[i]) return pa[i] < pb[i] ? -1 : 1
    }
    if (pa[3] == pb[3]) return 0
    if (pa[3] == '') return 1
    if (pb[3] == '') return -1
    return pa[3] <=> pb[3]
}

// ECR image-scan gate — fails closed. Polls until the scan reaches COMPLETE,
// then refuses any CRITICAL finding. An image whose scan never completes is
// treated as unsafe: the previous `|| true` wait let an unscanned image
// straight through to a deploy.
def assertImageScanned(String repoName, String imageId, String label) {
    def status = ''
    for (int attempt = 1; attempt <= 10; attempt++) {
        def probe = sh(
            script: "aws ecr describe-image-scan-findings --repository-name '${repoName}' --image-id ${imageId} --query 'imageScanFindings.scanStatus' --output text --no-cli-pager",
            returnStdout: true,
            returnStatus: true
        )
        // returnStdout+returnStatus yields a Map {status, stdout}, not an Integer.
        if (probe.status == 0) {
            status = probe.stdout?.trim() ?: ''
        }
        if (status == 'COMPLETE') {
            break
        }
        echo "  ECR scan ${status ?: 'PENDING'} for ${label} (attempt ${attempt}/10)"
        sleep(time: 30, unit: 'SECONDS')
    }
    if (status != 'COMPLETE') {
        error "ECR scan did not reach COMPLETE for ${imageId} after 5m — refusing to deploy an unscanned image"
    }

    def findingsText = sh(
        script: "aws ecr describe-image-scan-findings --repository-name '${repoName}' --image-id ${imageId} --query 'imageScanFindings' --output json --no-cli-pager",
        returnStdout: true
    ).trim()
    // A scan that completes with no findingSeverityCounts key is NOT a pass:
    // treat a missing key as "unknown", never as "zero findings".
    def findings = readJSON text: findingsText
    def counts = findings?.findingSeverityCounts
    if (counts == null) {
        error "ECR scan returned no findingSeverityCounts for ${imageId}"
    }
    def critical = (counts?.CRITICAL == null) ? 0 : counts.CRITICAL
    if (critical > 0) {
        error "ECR scan found ${critical} CRITICAL findings for ${imageId}"
    }
    echo "  ECR scan clean for ${imageId}"
}

// ---- Pipeline Definition ----------------------------------------------------
pipeline {
    agent { label 'jenkins-slave' }

    options {
        disableConcurrentBuilds()
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '50'))
        timeout(time: 20, unit: 'MINUTES')
        rateLimitBuilds(throttle: [count: 3, durationName: 'hour', userBoost: false])
    }

    // ---- Parameters -----------------------------------------------------------
    // The git tag to build and deploy. Filled in by the developer when manually
    // triggering one of the three environment jobs.
    parameters {
        string(name: 'GIT_TAG', defaultValue: '',
               description: 'Git tag to build and deploy (e.g. 1.2.3)')
        // Per-job defaults come from the Job DSL
        // (terraform/user-data/flowharbor-jobs.groovy): REBUILD is true for dev
        // only, so staging and prod promote the digest dev built.
        booleanParam(name: 'REBUILD', defaultValue: false,
                     description: 'Build and push a new image. When false, deploy the image already in ECR for this tag.')
        booleanParam(name: 'ALLOW_UNSIGNED_TAGS', defaultValue: false,
                     description: 'Deploy even though the tag commit is not GPG-signed.')
    }

    // ---- Environment Variables ------------------------------------------------
    // These variables are available to all stages in the pipeline.
    environment {
        // AWS region where all infrastructure lives (Mumbai, ap-south-1).
        AWS_DEFAULT_REGION = 'ap-south-1'

        // The ECR repository URL is injected via a Jenkins credential of type
        // "string". This credential was pre-created during the Jenkins master
        // bootstrap process (see terraform/user-data/jenkins-master.sh).
        ECR_REPOSITORY = credentials('ecr-repository-url')

        // The SNS topic used to publish the deploy outcome. Pre-created during
        // the Jenkins master bootstrap (see terraform/user-data/jenkins-master.sh).
        ALERTS_TOPIC_ARN = credentials('alerts-topic-arn')

        // Name of the ECS cluster that hosts the Fargate services.
        CLUSTER_NAME = 'flowharbor-cluster'

        // Target environment is derived from the job name suffix:
        //   flowharbor-dev → dev, flowharbor-staging → staging, flowharbor-prod → prod
        TARGET_ENV = env.JOB_NAME.tokenize('-').last()

        // Pipeline URL and deploy timestamp (git metadata is captured in the
        // "Checkout Tag" stage so it reflects the checked-out tag, not main).
        PIPELINE_URL = "${env.BUILD_URL}"
        TIMESTAMP = sh(script: "date -u +'%Y-%m-%dT%H:%M:%SZ'", returnStdout: true).trim()
    }

    // ---- Pipeline Stages ------------------------------------------------------
    stages {

        // === Stage 1: Checkout Tag =============================================
        // Validate TARGET_ENV allowlist + GIT_TAG, resolve tag to SHA, verify,
        // clean workspace and check out the SHA.
        stage('Checkout Tag') {
            steps {
                script {
                    if (!(['dev', 'staging', 'prod'].contains(TARGET_ENV))) {
                        error "REFUSING to deploy: invalid TARGET_ENV '${TARGET_ENV}' from JOB_NAME '${env.JOB_NAME}'. Allowed: ['dev','staging','prod']"
                    }
                    if (!params.GIT_TAG?.trim()) {
                        error "GIT_TAG parameter is required. Enter the git tag to deploy (e.g. 1.2.3)."
                    }
                    // Normalize the parameter once (trim whitespace) and reuse it
                    // everywhere so the image tag is always a valid ECR tag.
                    env.GIT_TAG = params.GIT_TAG.trim()
                    // The tag is interpolated into shell commands below, so it
                    // MUST be restricted to a safe semver-ish pattern. Without
                    // this, a malicious tag value could inject shell commands
                    // or arbitrary JavaScript (it also becomes the VERSION the
                    // app renders and bakes into runtime-config.js).
                    if (!(env.GIT_TAG ==~ /^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$/)) {
                        error "GIT_TAG '${env.GIT_TAG}' is invalid. Use semver format, e.g. 1.2.3 or 1.2.3-rc.1"
                    }
                    echo "Checking out git tag: ${env.GIT_TAG}"
                    sh "git fetch --tags --force --prune"
                    // Resolve tag to immutable commit SHA immediately (tags are mutable).
                    def tagSha = sh(script: "git rev-parse --verify 'refs/tags/${env.GIT_TAG}^{commit}'", returnStdout: true).trim()
                    if (!(tagSha ==~ /^[0-9a-f]{40}$/)) {
                        error "Cannot resolve tag '${env.GIT_TAG}' to a commit SHA (got '${tagSha}')"
                    }
                    // Require a signed tag/commit. An unsigned release is a hard
                    // failure unless the operator explicitly sets
                    // ALLOW_UNSIGNED_TAGS on the job.
                    def verifyStatus = sh(script: "git verify-tag '${env.GIT_TAG}' 2>&1 || git verify-commit '${tagSha}' 2>&1 || true", returnStdout: true).trim()
                    echo "  Tag verify: ${verifyStatus.take(300)}"
                    if (verifyStatus.contains("no signature found") || verifyStatus.contains("cannot verify")) {
                        if (env.ALLOW_UNSIGNED_TAGS != 'true') {
                            error "Unsigned tag/commit ${tagSha} for ${env.GIT_TAG} — refusing to deploy; set ALLOW_UNSIGNED_TAGS to override"
                        }
                        echo "  ALLOW_UNSIGNED_TAGS=true: deploying unsigned tag by explicit operator override."
                    }
                    // Clean workspace before checkout to remove stale artifacts.
                    sh "git clean -fdx"
                    sh "git checkout -f ${tagSha}"
                    sh "git rev-parse HEAD | grep -qx ${tagSha}"
                    env.GIT_TAG_SHA = tagSha

                    // Capture git metadata AFTER the tag checkout so it reflects
                    // the exact released commit being deployed. Sanitize author
                    // (issue #20): user.name is attacker-controlled; strip
                    // newlines (log-spoof), allowlist chars, truncate to 32.
                    env.GIT_COMMIT_SHORT = sh(script: "git rev-parse --short HEAD", returnStdout: true).trim().take(12)
                    env.GIT_BRANCH = env.GIT_TAG.take(32)
                    def rawAuthor = sh(script: "git log -1 --pretty=format:'%an'", returnStdout: true).trim()
                    env.GIT_AUTHOR = rawAuthor.replaceAll(/[\r\n]+/, ' ').replaceAll(/[^\p{L}\p{N} ._\-@]+/, '').trim().take(32)
                    if (!env.GIT_AUTHOR) { env.GIT_AUTHOR = 'unknown' }
                    echo "  Commit:  ${env.GIT_COMMIT_SHORT}"
                    echo "  Author:  ${env.GIT_AUTHOR}"
                }
            }
        }

        // === Stage 2: Verify ===================================================
        // Run the full local quality suite BEFORE anything is built or pushed.
        // A lint/typecheck/coverage failure here stops the run before a single
        // image layer exists, and the SBOM is archived as the supply-chain
        // artifact for the tag under release.
        stage('Verify') {
            steps {
                dir('app') {
                    sh "npm ci --ignore-scripts && npm run lint && npm run typecheck && npm run test:coverage"
                    // cyclonedx-npm is an app/ devDependency, so it only resolves
                    // from app/node_modules — there is no root package.json.
                    // Write one level up so archiveArtifacts (workspace-relative)
                    // finds it, matching the repo's own `sbom` script.
                    sh "npx --no-install cyclonedx-npm --output-file ../sbom-${env.GIT_TAG}.cdx.json --spec-version 1.6 --omit dev"
                }
                archiveArtifacts artifacts: "sbom-*.cdx.json", fingerprint: true
            }
        }

        // === Stage 3: Build ====================================================
        // Build the Docker image from the checked-out application source (app/).
        // Tagged with GIT_TAG only — no :latest (ECR is IMMUTABLE, deploy by digest).
        // Runs only when REBUILD=true: staging/prod promote the dev digest
        // instead of rebuilding it.
        // NOTE: `npm ci` moved to the Verify stage — it now runs once per build.
        stage('Build') {
            when { expression { return env.REBUILD == 'true' } }
            steps {
                script {
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  Building Docker image"
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  Repo:    ${ECR_REPOSITORY}"
                    echo "  Tag:     ${env.GIT_TAG}"
                    echo "  SHA:     ${env.GIT_TAG_SHA}"
                    echo "  Env:     ${TARGET_ENV}"
                    echo "  Commit:  ${GIT_COMMIT_SHORT}"
                    echo "  Author:  ${GIT_AUTHOR}"

                    dir('app') {
                        sh "npm audit --audit-level=high"
                    }

                    // Validate ECR before any docker login (fail closed, issue #20).
                    def REPO_NAME = ecrRepoName(ECR_REPOSITORY)
                    echo "  ECR repo:  ${REPO_NAME}"
                    sh "docker build -t \"${ECR_REPOSITORY}:${env.GIT_TAG}\" -f app/Dockerfile app/"

                    def imageInspect = sh(
                        script: "docker images \"${ECR_REPOSITORY}:${env.GIT_TAG}\" --format '{{.CreatedSince}}'",
                        returnStdout: true
                    ).trim()
                    echo "  Built:   ${imageInspect}"
                }
            }
        }

        // === Stage 3: Push to ECR ==============================================
        // Authenticate, push GIT_TAG only, resolve + verify digest, scan gate.
        stage('Push to ECR') {
            when { expression { return env.REBUILD == 'true' } }
            steps {
                script {
                    // Single validated repo name (issue #20: no split('/')[1]).
                    def REPO_NAME = ecrRepoName(ECR_REPOSITORY)
                    sh """
                        aws ecr get-login-password --region ${AWS_DEFAULT_REGION} | \
                        docker login --username AWS --password-stdin "${ECR_REPOSITORY}"
                    """

                    sh "docker push \"${ECR_REPOSITORY}:${env.GIT_TAG}\""

                    env.IMAGE_DIGEST = sh(
                        script: "aws ecr describe-images --repository-name \"${REPO_NAME}\" --image-ids imageTag=\"${env.GIT_TAG}\" --query 'imageDetails[0].imageDigest' --output text",
                        returnStdout: true
                    ).trim()
                    if (!env.IMAGE_DIGEST || env.IMAGE_DIGEST == "None") {
                        error "Failed to resolve digest for tag ${env.GIT_TAG}"
                    }
                    env.IMAGE_URI_BY_DIGEST = "${ECR_REPOSITORY}@${env.IMAGE_DIGEST}"
                    // Cross-verify local push matches remote digest.
                    def repoDigests = sh(script: "docker inspect --format='{{.RepoDigests}}' \"${ECR_REPOSITORY}:${env.GIT_TAG}\"", returnStdout: true).trim()
                    echo "  RepoDigests: ${repoDigests}"
                    if (!repoDigests.contains(env.IMAGE_DIGEST)) {
                        error "Digest mismatch: local RepoDigests ${repoDigests} does not contain ${env.IMAGE_DIGEST}"
                    }

                    // Scan gate: fail closed. An image that never reaches
                    // COMPLETE, or that reports CRITICAL findings, is refused.
                    assertImageScanned(REPO_NAME, "imageTag=${env.GIT_TAG}", env.GIT_TAG)
                    env.IMAGE_BUILT_AT = sh(
                        script: "aws ecr describe-images --repository-name \"${REPO_NAME}\" --image-ids imageTag=\"${env.GIT_TAG}\" --query 'imageDetails[0].imagePushedAt' --output text --no-cli-pager",
                        returnStdout: true
                    ).trim()
                    writeJSON file: "image-metadata-${env.BUILD_ID}.json", json: [tag: env.GIT_TAG, sha: env.GIT_TAG_SHA, digest: env.IMAGE_DIGEST, uriByDigest: env.IMAGE_URI_BY_DIGEST, commit: env.GIT_COMMIT_SHORT, mode: "built", pushedAt: env.IMAGE_BUILT_AT]
                    archiveArtifacts artifacts: "image-metadata-${env.BUILD_ID}.json", fingerprint: true

                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  Pushed to ECR"
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  Image: ${ECR_REPOSITORY}:${env.GIT_TAG}"
                    echo "  Digest: ${env.IMAGE_DIGEST}"
                    echo "  URI: ${env.IMAGE_URI_BY_DIGEST}"
                }
            }
        }

        // === Stage 5: Resolve Release =========================================
        // Runs only when REBUILD=false (staging/prod promotion). Resolves the
        // digest dev already built for this tag and re-asserts the scan gate, so
        // a promotion can never rebuild, substitute, or skip the scan.
        stage('Resolve Release') {
            when { expression { return env.REBUILD != 'true' } }
            steps {
                script {
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  Resolving pre-built image for ${env.GIT_TAG}"
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

                    def REPO_NAME = ecrRepoName(ECR_REPOSITORY)
                    echo "  ECR repo:  ${REPO_NAME}"
                    sh """
                        aws ecr get-login-password --region ${AWS_DEFAULT_REGION} | \
                        docker login --username AWS --password-stdin "${ECR_REPOSITORY}"
                    """

                    def imageText = sh(
                        script: "aws ecr describe-images --repository-name \"${REPO_NAME}\" --image-ids imageTag=\"${env.GIT_TAG}\" --query 'imageDetails[0]' --output json --no-cli-pager",
                        returnStdout: true
                    ).trim()
                    def image = readJSON text: imageText
                    def digest = image?.imageDigest
                    if (!digest) {
                        error "No image for tag ${env.GIT_TAG} in ${REPO_NAME} — run flowharbor-dev with REBUILD=true first"
                    }
                    if (!(digest ==~ /^sha256:[0-9a-f]{64}$/)) {
                        error "malformed digest ${digest}"
                    }
                    env.IMAGE_DIGEST = digest
                    env.IMAGE_URI_BY_DIGEST = "${ECR_REPOSITORY}@${digest}"
                    env.IMAGE_BUILT_AT = image?.imagePushedAt ?: ''
                    echo "  Digest: ${env.IMAGE_DIGEST}"
                    echo "  URI:    ${env.IMAGE_URI_BY_DIGEST}"
                    echo "  Pushed: ${env.IMAGE_BUILT_AT}"

                    // The promotion path never pushed, so it gates independently.
                    assertImageScanned(REPO_NAME, "imageDigest=${digest}", env.GIT_TAG)

                    writeJSON file: "image-metadata-${env.BUILD_ID}.json", json: [tag: env.GIT_TAG, sha: env.GIT_TAG_SHA, digest: env.IMAGE_DIGEST, uriByDigest: env.IMAGE_URI_BY_DIGEST, commit: env.GIT_COMMIT_SHORT, mode: "promoted", pushedAt: env.IMAGE_BUILT_AT]
                    archiveArtifacts artifacts: "image-metadata-${env.BUILD_ID}.json", fingerprint: true
                }
            }
        }

        // === Stage 6: Approval (prod only) =====================================
        // Manual approval gate for production. The submitter list is a list of
        // ACCOUNTS, enforced by the Global Matrix in jenkins/casc/jenkins.yaml:
        // they need Job/Build to reach the button at all.
        // Non-prod jobs skip via when.
        stage('Approval') {
            when { expression { return env.TARGET_ENV == 'prod' } }
            steps {
                timeout(time: 30, unit: 'MINUTES') {
                    input message: "Approve PROD deploy of tag ${env.GIT_TAG}?",
                          ok: 'Deploy to prod',
                          submitter: 'release-managers,admin'
                }
            }
        }

        // === Stage 7: Deploy ===================================================
        // Deploy the digest-pinned image resolved by Push to ECR (REBUILD=true)
        // or by Resolve Release (REBUILD=false) to this job's target environment.
        // Prod requires the Approval stage + staging promotion-chain check.
        stage('Deploy') {
            steps {
                script { promote(TARGET_ENV) }
            }
        }
    }

    // ---- Post-Build Actions ---------------------------------------------------
    // Regardless of outcome, certain actions run after all stages complete.
    post {
        always {
            // Secure cleanup: never leave task-def JSON or metadata in workspace.
            // Single-quoted Groovy string on purpose: ${...} here belongs to the
            // shell, and a GString would try (and fail) to interpolate it.
            sh(script: 'rm -f td.json; rm -f image-metadata-*.json; if [ -n "${WORKSPACE_TMP:-}" ]; then rm -f "$WORKSPACE_TMP"/td-*.json; fi', returnStatus: true)
        }
        // On success, print a detailed summary banner showing which environment
        // and tag were deployed.
        success {
            script {
                def envLabel = [
                    dev:     "Dev",
                    staging: "Staging",
                    prod:    "Production"
                ][TARGET_ENV] ?: "Unknown"
                def envUrl = [
                    dev:     "https://testing.flowharbor.in",
                    staging: "https://staging.flowharbor.in",
                    prod:    "https://flowharbor.in"
                ][TARGET_ENV] ?: "#"
                def shortImage = "${ECR_REPOSITORY}:${env.GIT_TAG}".take(38)
                def shortPipeline = (PIPELINE_URL ?: '').take(30)
                echo ""
                echo "╔══════════════════════════════════════════════════╗"
                echo "║           DEPLOYMENT COMPLETE                    ║"
                echo "╠══════════════════════════════════════════════════╣"
                echo "║  Env:     ${box(envLabel, 28)}           ║"
                echo "║  Tag:     ${box(env.GIT_TAG, 28)}           ║"
                echo "║  Commit:  ${box(GIT_COMMIT_SHORT, 28)}           ║"
                echo "║  Author:  ${box(GIT_AUTHOR, 28)}           ║"
                echo "║  Image:   ${box(shortImage, 28)}           ║"
                echo "║  Digest:  ${box((env.IMAGE_DIGEST ?: 'unknown').take(38), 28)}           ║"
                echo "╠══════════════════════════════════════════════════╣"
                echo "║  URL:     ${box(envUrl, 28)}  ║"
                echo "╠══════════════════════════════════════════════════╣"
                echo "║  Jenkins: ${box(shortPipeline, 28)}  ║"
                echo "╚══════════════════════════════════════════════════╝"
                echo ""
            }
            // Publish the deploy outcome so a green pipeline is not the only
            // signal that a release happened. Guarded and run with returnStatus
            // so a missing topic can never turn a successful deploy red.
            script {
                if (env.ALERTS_TOPIC_ARN) {
                    sh(
                        script: "aws sns publish --region ${AWS_DEFAULT_REGION} --topic-arn '${env.ALERTS_TOPIC_ARN}' --subject 'FlowHarbor ${TARGET_ENV} SUCCESS' --message 'FlowHarbor ${TARGET_ENV} ${env.GIT_TAG} ${env.IMAGE_DIGEST} ${env.BUILD_URL} SUCCESS'",
                        returnStatus: true
                    )
                }
            }
        }

        // On abort, log the stage where the pipeline was cancelled.
        aborted {
            echo "Pipeline aborted at stage: ${env.STAGE_NAME}"
        }

        // On failure, roll the service back if we moved it, then notify.
        // The rollback is armed by promote() only once it is about to call
        // update-service, so an earlier failure (a failed gate, a failed
        // services-stable wait) leaves the running service untouched.
        failure {
            echo "Pipeline failed at stage: ${env.STAGE_NAME}"
            script {
                if (env.DEPLOY_ATTEMPTED == 'true' && env.PREVIOUS_TASK_DEFINITION_REVISION) {
                    echo "  Rolling back ${env.SERVICE_NAME} to ${env.PREVIOUS_TASK_DEFINITION_REVISION}"
                    try {
                        sh """
                            aws ecs update-service \
                                --cluster ${CLUSTER_NAME} \
                                --service ${env.SERVICE_NAME} \
                                --task-definition ${env.PREVIOUS_TASK_DEFINITION_REVISION} \
                                --force-new-deployment
                        """
                        sh "timeout 600 aws ecs wait services-stable --cluster ${CLUSTER_NAME} --services ${env.SERVICE_NAME}"
                        echo "  ROLLBACK OK: ${env.SERVICE_NAME} is back on ${env.PREVIOUS_TASK_DEFINITION_REVISION}"
                    } catch (rollbackErr) {
                        echo "ROLLBACK FAILED — ${env.SERVICE_NAME} may still be on the bad revision; run: aws ecs update-service --cluster flowharbor-cluster --service ${env.SERVICE_NAME} --task-definition ${env.PREVIOUS_TASK_DEFINITION_REVISION}"
                    }
                }
                // Never fail the build on a notification problem: a wrong or
                // missing topic must not mask the real failure.
                if (env.ALERTS_TOPIC_ARN) {
                    sh(
                        script: "aws sns publish --region ${AWS_DEFAULT_REGION} --topic-arn '${env.ALERTS_TOPIC_ARN}' --subject 'FlowHarbor ${TARGET_ENV} FAILURE' --message 'FlowHarbor ${TARGET_ENV} ${env.GIT_TAG} ${env.IMAGE_DIGEST} ${env.BUILD_URL} FAILURE'",
                        returnStatus: true
                    )
                }
                currentBuild.result = 'FAILURE'
            }
        }
    }
}

// =============================================================================
// promote(envName) — Deploy the current image to a target environment
// =============================================================================
// This function encapsulates the ECS deployment logic for a single environment.
// Steps:
//   1. Fetch the current task definition for the target family (e.g., flowharbor-staging).
//   2. Build a new container definition that points to ${ECR_REPOSITORY}:${GIT_TAG}
//      and includes CI/CD metadata as environment variables.
//   3. Register a new task definition revision.
//   4. Update the ECS service to use the new revision (triggering a rolling update).
//   5. Wait for the service to stabilize.
//   6. Log the result with service status.
//
// Parameters:
//   envName — one of "dev", "staging", "prod" (maps to ECS family and service names).
// =============================================================================
def promote(envName) {
    if (!(['dev', 'staging', 'prod'].contains(envName))) {
        error "REFUSING to deploy: invalid env '${envName}' from JOB_NAME '${env.JOB_NAME}'. Allowed: ['dev','staging','prod']"
    }
    // Derive the ECS task definition family and service name from the environment.
    // Pattern: flowharbor-{dev|staging|prod}
    def family = "flowharbor-${envName}"
    def serviceName = "flowharbor-${envName}"

    // Map the internal environment name to a human-readable label and URL.
    def envLabel = [
        dev:     "Dev",
        staging: "Staging",
        prod:    "Production"
    ][envName] ?: "Unknown"

    def envUrl = [
        dev:     "https://testing.flowharbor.in",
        staging: "https://staging.flowharbor.in",
        prod:    "https://flowharbor.in"
    ][envName] ?: "#"

    // Log the deployment target for pipeline visibility.
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Deploying to ${envLabel} (${envName})"
    echo "  URL: ${envUrl}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    // ---- Fetch Current Task Definition ----------------------------------------
    // Retrieve the current (latest) active task definition for the family.
    // This gives us the base container definition to modify.
    def currentTd = sh(
        script: "aws ecs describe-task-definition --task-definition ${family}",
        returnStdout: true
    ).trim()

    // Parse the JSON response and extract the first container definition.
    def td = readJSON text: currentTd
    def containerDef = td.taskDefinition.containerDefinitions[0]

    // ---- Build New Container Definition ---------------------------------------
    // Create an updated container definition that:
    //   - Uses the digest-pinned image (repo@sha256:...), never a mutable tag
    //   - Injects all CI/CD metadata as environment variables for runtime display
    def deployImage = env.IMAGE_URI_BY_DIGEST ?: "${ECR_REPOSITORY}:${env.GIT_TAG}"
    if (!(deployImage.contains('@sha256:'))) {
        error "REFUSING to deploy by mutable tag: '${deployImage}'. Digest pin required."
    }

    // ---- Promotion-chain check (prod only) ------------------------------------
    // Prod may only deploy an image already validated in staging. Compare the
    // staging task definition image against the image under deployment; fail closed.
    if (envName == 'prod') {
        def stagingDesc = sh(
            script: "aws ecs describe-task-definition --task-definition flowharbor-staging",
            returnStdout: true
        ).trim()
        def stagingTd = readJSON text: stagingDesc
        def stagingImage = stagingTd.taskDefinition.containerDefinitions[0].image
        if (stagingImage != deployImage) {
            error "Promotion chain violated: prod image ${deployImage} != staging image ${stagingImage}. Deploy to staging first."
        }
        echo "  Promotion chain OK: matches staging"
    }

    // ---- No-op / churn guard --------------------------------------------------
    // If the target env already runs this exact image+env, skip the update to
    // avoid deploy churn / DoS via repeated identical deployments.
    def imageChanged = (containerDef.image != deployImage)
    // ---- Downgrade guard (issue #20) ------------------------------------------
    // Refuse to deploy an older semver VERSION over a newer one (silent
    // rollback would reintroduce CVEs). Same-version rebuilds allowed.
    def currentVersion = ((containerDef.environment ?: []).find { it.name == 'VERSION' })?.value ?: ''
    if (imageChanged && currentVersion?.trim() && env.GIT_TAG?.trim()) {
        def cmp = compareSemver(env.GIT_TAG, currentVersion)
        if (cmp < 0) {
            error "REFUSING downgrade: ${currentVersion} -> ${env.GIT_TAG} in ${envName}. Deploy a version >= current."
        }
    }
    if (!imageChanged) {
        echo "No-op: image ${deployImage} already deployed to ${envName}; skipping update."
        return
    }

    // ---- Rollback bookkeeping -------------------------------------------------
    // Record what we are rolling away from, and which service/family we are
    // touching, so post { failure } can restore the previous revision by itself
    // if the update-service call or the services-stable wait fails.
    // Deliberately NOT @NonCPS: promote() calls readJSON/writeJSON, whose Map
    // returns are not @NonCPS-safe. The extra sh round-trips are cheaper than a
    // CPS refactor of this function.
    env.SERVICE_NAME = serviceName
    env.TARGET_FAMILY = family
    env.PREVIOUS_TASK_DEFINITION_REVISION = "${family}:${td.taskDefinition.revision}"

    // ---- Mutate-in-place + secrets publish (issue #15) --------------------------
    // Mutate the CURRENT container definition: only swap image + non-secret
    // env values. This preserves Terraform-owned hardening (user,
    // readonlyRootFilesystem, privileged, linuxParameters, healthCheck,
    // mountPoints, secrets). The previous allowlist rebuild dropped all of
    // these on every deploy.
    // GIT_AUTHOR/PIPELINE_URL are delivered via the `secrets` block (SSM
    // SecureString), never plaintext `environment`. Values are published
    // first so the new revision resolves them at launch. Requires the slave
    // ssm:PutParameter grant on /flowharbor/{dev,staging,prod}/* (iam module).
    // NOTE: \$ escapes Groovy interpolation so the SHELL expands these from
    // the Jenkins environment (avoids quote-injection via author names).
    sh """
        aws ssm put-parameter --name '/flowharbor/${envName}/GIT_AUTHOR' \
            --value "\$GIT_AUTHOR" --type SecureString --overwrite --tier Standard >/dev/null
        aws ssm put-parameter --name '/flowharbor/${envName}/PIPELINE_URL' \
            --value "\$PIPELINE_URL" --type SecureString --overwrite --tier Standard >/dev/null
    """
    def newEnvValues = [
        "ENV"         : envName,
        "VERSION"     : env.GIT_TAG,
        "BUILD_NUMBER": "${BUILD_NUMBER}",
        "GIT_COMMIT"  : GIT_COMMIT_SHORT,
        "GIT_BRANCH"  : GIT_BRANCH,
        "TIMESTAMP"   : TIMESTAMP
    ]
    def secretNames = ["GIT_AUTHOR", "PIPELINE_URL"] as Set
    // Update existing entries, drop leaked secret-names from environment, add
    // missing plaintext keys. Unknown pre-existing keys are preserved as-is.
    def mergedEnv = []
    def seen = [] as Set
    (containerDef.environment ?: []).each { e ->
        if (secretNames.contains(e.name)) {
            return // Must come from `secrets`, never `environment`.
        }
        if (newEnvValues.containsKey(e.name)) {
            mergedEnv << [name: e.name, value: newEnvValues[e.name]]
            seen << e.name
        } else {
            mergedEnv << e
        }
    }
    newEnvValues.each { k, v ->
        if (!seen.contains(k)) {
            mergedEnv << [name: k, value: v]
        }
    }
    containerDef.image = deployImage
    containerDef.environment = mergedEnv
    // Repair the secrets block if an old revision predates issue #15.
    def awsAccount = sh(script: "aws sts get-caller-identity --query Account --output text", returnStdout: true).trim()
    def secretBase = "arn:aws:ssm:${AWS_DEFAULT_REGION}:${awsAccount}:parameter/flowharbor/${envName}"
    def preservedSecrets = (containerDef.secrets ?: []).findAll { !(it.name in secretNames) }
    containerDef.secrets = preservedSecrets + [
        [name: "GIT_AUTHOR", valueFrom: "${secretBase}/GIT_AUTHOR"],
        [name: "PIPELINE_URL", valueFrom: "${secretBase}/PIPELINE_URL"]
    ]
    def newContainerDef = containerDef

    // Preserve the runtime platform from the existing task definition, defaulting
    // to ARM64 Linux if not set (for compatibility with older revisions).
    def rp = td.taskDefinition.runtimePlatform ?: [cpuArchitecture: 'ARM64', operatingSystemFamily: 'LINUX']

    // ---- Construct New Task Definition Payload --------------------------------
    // Build the full payload for registering a new task definition revision.
    // We reuse most fields from the current revision (roles, network, CPU/memory)
    // but substitute the updated container definition.
    def payload = [
        family: family,
        taskRoleArn: td.taskDefinition.taskRoleArn,
        executionRoleArn: td.taskDefinition.executionRoleArn,
        networkMode: td.taskDefinition.networkMode,
        requiresCompatibilities: td.taskDefinition.requiresCompatibilities,
        cpu: td.taskDefinition.cpu,
        memory: td.taskDefinition.memory,
        runtimePlatform: rp,
        volumes: td.taskDefinition.volumes ?: [[name: 'tmp'], [name: 'public']],
        containerDefinitions: [newContainerDef]
    ]

    // Write the payload to an isolated per-build temp file for the AWS CLI call.
    def tdFile = "${env.WORKSPACE_TMP}/td-${env.BUILD_ID}.json"
    writeJSON file: tdFile, json: payload

    // ---- Register New Task Definition Revision --------------------------------
    def newTd = null
    try {
        newTd = sh(
            script: "aws ecs register-task-definition --cli-input-json file://${tdFile}",
            returnStdout: true
        ).trim()
    } finally {
        sh(script: "test -f '${tdFile}' && shred -u '${tdFile}' || true", returnStatus: true)
    }

    // Extract the new revision ARN and number from the response.
    def tdResult = readJSON(text: newTd)
    def tdArn = tdResult.taskDefinition.taskDefinitionArn
    def revision = tdResult.taskDefinition.revision

    echo "  Task Definition: ${family}:${revision}"

    // ---- Post-register hardening assertion (issue #15) ------------------------
    // Fail closed if the new revision lost hardening (e.g. a future edit
    // reintroduces an allowlist rebuild). Checks: digest pin, non-root user,
    // readonly FS, health check, /tmp + /app/public mounts, secrets present
    // and absent from plaintext environment.
    def regDef = tdResult.taskDefinition.containerDefinitions[0]
    def regEnvNames = ((regDef.environment ?: []).collect { it.name }) as Set
    def regSecretNames = ((regDef.secrets ?: []).collect { it.name }) as Set
    def regMounts = ((regDef.mountPaths ?: regDef.mountPoints ?: []).collect { it.containerPath }) as Set
    assert regDef.image.contains('@sha256:') : "ASSERT: image not digest-pinned: ${regDef.image}"
    assert regDef.user == 'node' : "ASSERT: user != node (got '${regDef.user}')"
    assert regDef.readonlyRootFilesystem == true : "ASSERT: readonlyRootFilesystem lost"
    assert regDef.healthCheck != null : "ASSERT: healthCheck missing"
    assert regMounts.contains('/tmp') : "ASSERT: /tmp mount missing"
    assert regMounts.contains('/app/public') : "ASSERT: /app/public mount missing"
    assert regSecretNames.contains('GIT_AUTHOR') && regSecretNames.contains('PIPELINE_URL') : "ASSERT: secrets missing (got ${regSecretNames})"
    assert !(regEnvNames.contains('GIT_AUTHOR') || regEnvNames.contains('PIPELINE_URL')) : "ASSERT: secrets leaked into environment"
    echo "  Hardening assertion OK: digest-pinned, user=node, readonlyRootFS, healthCheck, mounts, secrets"

    // ---- Update ECS Service ---------------------------------------------------
    // Tell ECS to update the service to use the new task definition revision.
    // --force-new-deployment is passed ONLY when the image actually changed
    // (imageChanged, checked above); otherwise it is omitted to avoid churn.
    // The no-op early return above already skips identical redeploys.
    def forceFlag = imageChanged ? '--force-new-deployment' : ''
    // From here on, any failure must trigger the automatic rollback in
    // post { failure }, so arm the flag immediately before the service update.
    env.DEPLOY_ATTEMPTED = 'true'
    sh """
        aws ecs update-service \
            --cluster ${CLUSTER_NAME} \
            --service ${serviceName} \
            --task-definition ${tdArn} \
            ${forceFlag}
    """

    // ---- Wait for Service Stability -------------------------------------------
    // Block until the ECS service reports as stable (all tasks in RUNNING state,
    // health checks passing, load balancer registration complete).
    // Bounded by timeout so a stuck deployment cannot hang executors (DoS).
    timeout(time: 10, unit: 'MINUTES') {
        sh """
            aws ecs wait services-stable \
                --cluster ${CLUSTER_NAME} \
                --services ${serviceName}
        """
    }

    // ---- Log Service Status ---------------------------------------------------
    // Fetch a summary of the service state for the pipeline logs.
    def serviceDesc = sh(
        script: "aws ecs describe-services --cluster ${CLUSTER_NAME} --services ${serviceName} --query 'services[0].{running: runningCount,desired: desiredCount,status: status}' --output json",
        returnStdout: true
    ).trim()

    echo "  Status: ${serviceDesc}"
    echo "  ${envLabel}: ${envUrl}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}
