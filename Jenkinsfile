#!/usr/bin/env groovy
/**
 * Jenkinsfile for homelab-smoke
 *
 * Builds and pushes the smoke test container image on every merge to main.
 * Uses semantic versioning based on git tags.
 *
 * Image: docker.nexus.erauner.dev/homelab/smoke:<version>
 */

@Library('homelab') _

pipeline {
    agent {
        kubernetes {
            yaml homelab.podTemplate('kaniko-go')
        }
    }

    options {
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timeout(time: 15, unit: 'MINUTES')
        disableConcurrentBuilds()
    }

    environment {
        IMAGE_NAME = 'docker.nexus.erauner.dev/homelab/smoke'
    }

    stages {
        stage('Test') {
            steps {
                container('golang') {
                    sh '''
                        apk add --no-cache git
                        echo "=== Running tests ==="
                        go test -v ./...
                    '''
                }
            }
        }

        stage('Build Check') {
            steps {
                container('golang') {
                    sh '''
                        echo "=== Verifying build ==="
                        go build -buildvcs=false -o /dev/null ./cmd/smoke
                    '''
                }
            }
        }

        stage('Build and Push Image') {
            steps {
                script {
                    // Get version info
                    env.VERSION = homelab.gitDescribe()
                    env.COMMIT = homelab.gitShortCommit()

                    echo "Building image version: ${env.VERSION} (commit: ${env.COMMIT})"

                    // Build and push using shared library
                    homelab.homelabBuild([
                        image: env.IMAGE_NAME,
                        version: env.VERSION,
                        commit: env.COMMIT,
                        dockerfile: 'Dockerfile',
                        context: '.'
                    ])
                }
            }
        }

        stage('Create Release Tag') {
            steps {
                container('golang') {
                    withCredentials([usernamePassword(
                        credentialsId: 'github-app',
                        usernameVariable: 'GIT_USER',
                        passwordVariable: 'GIT_TOKEN'
                    )]) {
                        script {
                            sh 'apk add --no-cache curl jq'  // git already in golang image

                            // Use shared library for release creation
                            def result = homelab.createPreRelease([
                                repo: 'erauner/homelab-smoke',
                                imageName: env.IMAGE_NAME,
                                imageTag: env.VERSION
                            ])
                            env.NEW_VERSION = result.version
                        }
                    }
                }
            }
        }
    }

    post {
        success {
            echo """
            ✅ Build successful!

            Image: ${env.IMAGE_NAME}:${env.VERSION}
            Tag: ${env.NEW_VERSION ?: 'N/A'}

            To pull: docker pull ${env.IMAGE_NAME}:${env.VERSION}
            """
        }
        failure {
            echo '❌ Build failed - check the logs'
        }
    }
}
