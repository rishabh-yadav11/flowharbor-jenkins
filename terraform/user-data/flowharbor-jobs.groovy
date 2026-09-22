// =============================================================================
// flowharbor-jobs.groovy — Job DSL source for the three FlowHarbor pipeline jobs
// =============================================================================
// Rendered by Terraform (templatefile) into /var/lib/jenkins/flowharbor-jobs.groovy
// on the Jenkins master at first boot, then executed at controller start by the
// `jobs: - file:` entry in jenkins/casc/jenkins.yaml.
//
// Every job:
//   - Is triggered MANUALLY only (no GitHub push trigger, no SCM polling)
//   - Loads the Jenkinsfile from the main branch (Jenkinsfile always current)
//   - Takes a required GIT_TAG string parameter (the git tag to build/deploy)
//   - Derives its target environment from the job name suffix
//
// REBUILD defaults to true for dev only, so staging and prod promote the exact
// image digest dev built instead of rebuilding it. The app source tag checkout
// happens inside the Jenkinsfile itself.
//
// Template variable (replaced by Terraform — the ONLY interpolation in this file):
//   ${github_repo} — owner/repo the Jenkinsfile is read from
//
// NOTE: this file is a Terraform template first and Groovy second. Any other
// dollar-brace sequence would be consumed by templatefile() before Groovy ever
// sees it, so per-environment names are built by concatenation, not GStrings.
// =============================================================================

def envs = ['dev', 'staging', 'prod']
envs.each { e ->
  pipelineJob('flowharbor-' + e) {
    description('Tag-driven build and deploy to ' + e + '. Manual trigger only.')
    logRotator { numToKeep(50) }
    parameters {
      stringParam('GIT_TAG', '', 'Git tag to build and deploy (semver, e.g. 1.2.3)')
      booleanParam('REBUILD', e == 'dev', 'Build and push a new image. When false, deploy the image already in ECR for this tag.')
      booleanParam('ALLOW_UNSIGNED_TAGS', false, 'Deploy even though the tag commit is not GPG-signed.')
    }
    definition {
      cpsScm {
        scm { git { remote { url('https://github.com/${github_repo}.git') }; branch('*/main') } }
        scriptPath('Jenkinsfile')
        lightweight(true)
      }
    }
  }
}
