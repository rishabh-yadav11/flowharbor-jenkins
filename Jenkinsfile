// =============================================================================
// Jenkinsfile — FlowHarbor CI/CD Pipeline
// =============================================================================
// This declarative Jenkins pipeline defines the entire build, push, and
// multi-environment deployment workflow for the FlowHarbor demo application.
//
// Pipeline stages (in order):
//   1. Build         — Docker image build from the application source
//   2. Push to ECR   — Authenticate with AWS ECR and push image tags
//   3. Deploy to Dev — Auto-deploy to the dev ECS environment
//   4. Approve Staging — Manual approval gate (admin-only)
//   5. Promote to Staging — Deploy the same image to staging
//   6. Approve Production — Manual approval gate (admin-only)
//   7. Promote to Production — Deploy to production
//
// On success, a summary banner with all promotion details is printed.
// On abort or failure, the pipeline logs the failing stage.
//
// The `promote()` function encapsulates the logic for registering a new ECS
// task definition revision and triggering a rolling service update.
// =============================================================================

// ---- Pipeline Definition ----------------------------------------------------
// The entire pipeline runs on a Jenkins agent labelled "jenkins-slave". This
// agent is expected to have Docker, AWS CLI, and git installed.
pipeline {
    agent { label 'jenkins-slave' }

    // ---- Environment Variables ------------------------------------------------
    // These variables are available to all stages in the pipeline.
    environment {
        // AWS region where all infrastructure lives (Mumbai, ap-south-1).
        AWS_DEFAULT_REGION = 'ap-south-1'

        // The ECR repository URL is injected via a Jenkins credential of type
        // "string". This credential was pre-created during the Jenkins master
        // bootstrap process (see terraform/user-data/jenkins-master.sh).
        ECR_REPOSITORY = credentials('ecr-repository-url')

        // Name of the ECS cluster that hosts the Fargate services.
        CLUSTER_NAME = 'flowharbor-cluster'


        // Git metadata extracted at pipeline start for display in the app and
        // for traceability throughout the deployment.
        GIT_COMMIT_SHORT = sh(script: "git rev-parse --short HEAD", returnStdout: true).trim()
        GIT_BRANCH = sh(script: "git rev-parse --abbrev-ref HEAD", returnStdout: true).trim()
        GIT_AUTHOR = sh(script: "git log -1 --pretty=format:'%an'", returnStdout: true).trim()
        PIPELINE_URL = "${env.BUILD_URL}"
        TIMESTAMP = sh(script: "date -u +'%Y-%m-%dT%H:%M:%SZ'", returnStdout: true).trim()
    }

    // ---- Pipeline Stages ------------------------------------------------------
    stages {

        // === Stage 1: Build ====================================================
        // Build the Docker image from the application source (app/ directory).
        // The image is tagged with both the Jenkins build number and "latest".
        // Build arguments and metadata are logged for traceability.
        stage('Build') {
            steps {
                script {
                    // Visual separator block for readable log output.
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  Building Docker image"
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  Repo:    ${ECR_REPOSITORY}"
                    echo "  Tag:     ${BUILD_NUMBER}"
                    echo "  Branch:  ${GIT_BRANCH}"
                    echo "  Commit:  ${GIT_COMMIT_SHORT}"
                    echo "  Author:  ${GIT_AUTHOR}"

                    // Build the image with the build number as tag. The BUILD_NUMBER
                    // arg is forwarded to the Dockerfile so the container knows which
                    // build produced it.
                    sh "docker build --build-arg BUILD_NUMBER=${BUILD_NUMBER} -t ${ECR_REPOSITORY}:${BUILD_NUMBER} -f app/Dockerfile app/"

                    // Also tag as "latest" so the ECS task definitions can reference
                    // a stable tag that always points to the most recent build.
                    sh "docker tag ${ECR_REPOSITORY}:${BUILD_NUMBER} ${ECR_REPOSITORY}:latest"

                    // Inspect the freshly built image and log when it was created.
                    def imageInspect = sh(
                        script: "docker images ${ECR_REPOSITORY}:${BUILD_NUMBER} --format '{{.CreatedSince}}'",
                        returnStdout: true
                    ).trim()
                    echo "  Built:   ${imageInspect}"
                }
            }
        }

        // === Stage 2: Push to ECR ==============================================
        // Authenticate Docker with the AWS ECR registry, then push both tags
        // (build-number and latest). The image digest is retrieved for auditing.
        stage('Push to ECR') {
            steps {
                script {
                    // Authenticate: get a temporary password from ECR and pipe it
                    // to `docker login`. This avoids storing long-lived credentials.
                    sh """
                        aws ecr get-login-password --region ${AWS_DEFAULT_REGION} | \
                        docker login --username AWS --password-stdin ${ECR_REPOSITORY}
                    """

                    // Push both tags to the remote registry.
                    sh "docker push ${ECR_REPOSITORY}:${BUILD_NUMBER}"
                    sh "docker push ${ECR_REPOSITORY}:latest"

                    // Retrieve the SHA256 digest of the pushed image for audit trails.
                    def digest = sh(
                        script: "aws ecr describe-images --repository-name ${ECR_REPOSITORY.split('/')[1]} --image-ids imageTag=${BUILD_NUMBER} --query 'imageDetails[0].imageDigest' --output text",
                        returnStdout: true
                    ).trim()

                    // Log the push result for pipeline output visibility.
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  Pushed to ECR"
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "  Image: ${ECR_REPOSITORY}:${BUILD_NUMBER}"
                    echo "  Digest: ${digest}"
                }
            }
        }

        // === Stage 3: Deploy to Dev ============================================
        // Automatically promote the new image to the dev environment. No manual
        // approval is needed for dev — it serves as the first integration test.
        stage('Deploy to Dev') {
            steps {
                script { promote('dev') }
            }
        }

        // === Stage 4: Approve Staging ==========================================
        // Manual input gate requiring an admin user to approve promotion to
        // staging. This is where a human validates dev before wider rollout.
        stage('Approve Staging') {
            steps {
                input message: "Promote build #${BUILD_NUMBER} (${GIT_COMMIT_SHORT}) to staging?",
                      ok: "Promote to Staging",
                      submitter: 'admin'
            }
        }

        // === Stage 5: Promote to Staging =======================================
        // Once approved, deploy the same image to the staging environment.
        stage('Promote to Staging') {
            steps {
                script { promote('staging') }
            }
        }

        // === Stage 6: Approve Production =======================================
        // A second manual approval gate before the most critical deployment.
        // This is the final safety check before production rollout.
        stage('Approve Production') {
            steps {
                input message: "Promote build #${BUILD_NUMBER} (${GIT_COMMIT_SHORT}) to production?",
                      ok: "Promote to Production",
                      submitter: 'admin'
            }
        }

        // === Stage 7: Promote to Production ====================================
        // Final deployment stage — pushes the image to production ECS service.
        stage('Promote to Production') {
            steps {
                script { promote('prod') }
            }
        }
    }

    // ---- Post-Build Actions ---------------------------------------------------
    // Regardless of outcome, certain actions run after all stages complete.
    post {
        // On success, print a detailed promotion summary banner showing which
        // build, version, commit, and branch were deployed to which environments.
        success {
            script {
                def envUrl = [
                    dev:     "https://testing.flowharbor.in",
                    staging: "https://staging.flowharbor.in",
                    prod:    "https://flowharbor.in"
                ]
                echo ""
                echo "╔══════════════════════════════════════════════════╗"
                echo "║           PROMOTION COMPLETE                    ║"
                echo "╠══════════════════════════════════════════════════╣"
                echo "║  Build:   #${BUILD_NUMBER.padLeft(6)}                          ║"
                echo "║  Version: ${params.VERSION?.padRight(28)}           ║"
                echo "║  Commit:  ${GIT_COMMIT_SHORT.padRight(28)}           ║"
                echo "║  Branch:  ${GIT_BRANCH.padRight(28)}           ║"
                echo "║  Author:  ${GIT_AUTHOR.padRight(28)}           ║"
                echo "║  Image:   ${ECR_REPOSITORY}:${BUILD_NUMBER}   ║"
                echo "╠══════════════════════════════════════════════════╣"
                echo "║  Dev:     https://testing.flowharbor.in  ║"
                echo "║  Staging: https://staging.flowharbor.in  ║"
                echo "║  Prod:    https://flowharbor.in          ║"
                echo "╠══════════════════════════════════════════════════╣"
                echo "║  Jenkins: ${PIPELINE_URL}  ║"
                echo "╚══════════════════════════════════════════════════╝"
                echo ""
            }
        }

        // On abort, log the stage where the pipeline was cancelled.
        aborted {
            echo "Pipeline aborted at stage: ${env.STAGE_NAME}"
        }

        // On failure, log the stage and explicitly set the result to FAILURE.
        failure {
            echo "Pipeline failed at stage: ${env.STAGE_NAME}"
            script {
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
//   1. Fetch the current task definition for the target family (e.g., flowharbor-dev).
//   2. Build a new container definition that points to ${ECR_REPOSITORY}:latest
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
    // Derive the ECS task definition family and service name from the environment.
    // Pattern: flowharbor-{dev|staging|prod}
    def family = "flowharbor-${envName}"
    def serviceName = "flowharbor-${envName}"

    // Map the internal environment name to a human-readable label and URL.
    def envLabel = [
        dev:     "Dev",
        staging: "Staging",
        prod:    "Production"
    ][envName]

    def envUrl = [
        dev:     "https://testing.flowharbor.in",
        staging: "https://staging.flowharbor.in",
        prod:    "https://flowharbor.in"
    ][envName]

    // Log the promotion target for pipeline visibility.
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Promoting to ${envLabel} (${envName})"
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
    //   - Uses the ":latest" image tag (just pushed in the ECR stage)
    //   - Injects all CI/CD metadata as environment variables for runtime display
    def newContainerDef = [
        name: containerDef.name,
        image: "${ECR_REPOSITORY}:latest",
        essential: containerDef.essential,
        portMappings: containerDef.portMappings,
        logConfiguration: containerDef.logConfiguration,
        // Environment variables are consumed by the app's entrypoint.sh to
        // render the build info on the web page at runtime.
        environment: [
            [name: "ENV", value: envName],
            [name: "VERSION", value: params.VERSION ?: "1.0.0"],
            [name: "BUILD_NUMBER", value: "${BUILD_NUMBER}"],
            [name: "GIT_COMMIT", value: GIT_COMMIT_SHORT],
            [name: "GIT_BRANCH", value: GIT_BRANCH],
            [name: "GIT_AUTHOR", value: GIT_AUTHOR],
            [name: "TIMESTAMP", value: TIMESTAMP],
            [name: "PIPELINE_URL", value: PIPELINE_URL]
        ]
    ]

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
        containerDefinitions: [newContainerDef]
    ]

    // Write the payload to a temp file for the AWS CLI call.
    writeJSON file: 'td.json', json: payload

    // ---- Register New Task Definition Revision --------------------------------
    def newTd = sh(
        script: "aws ecs register-task-definition --cli-input-json file://td.json",
        returnStdout: true
    ).trim()

    // Extract the new revision ARN and number from the response.
    def tdResult = readJSON(text: newTd)
    def tdArn = tdResult.taskDefinition.taskDefinitionArn
    def revision = tdResult.taskDefinition.revision

    echo "  Task Definition: ${family}:${revision}"

    // ---- Update ECS Service ---------------------------------------------------
    // Tell ECS to update the service to use the new task definition revision.
    // The --force-new-deployment flag ensures a new deployment is triggered
    // even if the service is already running (e.g., same image tag, new revision).
    sh """
        aws ecs update-service \
            --cluster ${CLUSTER_NAME} \
            --service ${serviceName} \
            --task-definition ${tdArn} \
            --force-new-deployment
    """

    // ---- Wait for Service Stability -------------------------------------------
    // Block until the ECS service reports as stable (all tasks in RUNNING state,
    // health checks passing, load balancer registration complete).
    sh """
        aws ecs wait services-stable \
            --cluster ${CLUSTER_NAME} \
            --services ${serviceName}
    """

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
