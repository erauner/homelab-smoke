#!/usr/bin/env groovy
/**
 * Jenkinsfile for homelab-smoke
 *
 * Builds and pushes the smoke test container image on every merge to main.
 * Also builds standalone binaries for multiple platforms (Linux, macOS).
 * Uses semantic versioning based on git tags.
 *
 * Image: docker.nexus.erauner.dev/homelab/smoke:<version>
 * Binaries: Uploaded to GitHub Releases as assets
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

        stage('Build Multi-Platform Binaries') {
            steps {
                container('golang') {
                    script {
                        // Get version info for ldflags
                        env.VERSION = homelab.gitDescribe()
                        env.COMMIT = homelab.gitShortCommit()
                        env.BUILD_DATE = sh(script: 'date -u +%Y-%m-%dT%H:%M:%SZ', returnStdout: true).trim()
                    }
                    sh '''
                        echo "=== Building multi-platform binaries ==="
                        echo "Version: ${VERSION}, Commit: ${COMMIT}"

                        mkdir -p dist

                        # Common ldflags for all builds
                        LDFLAGS="-s -w -X main.version=${VERSION} -X main.commit=${COMMIT} -X main.date=${BUILD_DATE}"

                        # Linux AMD64 (for CI/containers)
                        echo "Building linux/amd64..."
                        CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -buildvcs=false \
                            -ldflags="${LDFLAGS}" \
                            -o dist/smoke-linux-amd64 ./cmd/smoke

                        # Linux ARM64 (for ARM servers/Raspberry Pi)
                        echo "Building linux/arm64..."
                        CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -buildvcs=false \
                            -ldflags="${LDFLAGS}" \
                            -o dist/smoke-linux-arm64 ./cmd/smoke

                        # macOS AMD64 (Intel Macs)
                        echo "Building darwin/amd64..."
                        CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -buildvcs=false \
                            -ldflags="${LDFLAGS}" \
                            -o dist/smoke-darwin-amd64 ./cmd/smoke

                        # macOS ARM64 (Apple Silicon - M1/M2/M3)
                        echo "Building darwin/arm64..."
                        CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -buildvcs=false \
                            -ldflags="${LDFLAGS}" \
                            -o dist/smoke-darwin-arm64 ./cmd/smoke

                        # Show built binaries
                        echo "=== Built binaries ==="
                        ls -lh dist/
                    '''
                }
            }
        }

        stage('Build and Push Image') {
            steps {
                script {
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
                            env.RELEASE_ID = result.releaseId
                        }
                    }
                }
            }
        }

        stage('Upload Release Assets') {
            steps {
                container('golang') {
                    withCredentials([usernamePassword(
                        credentialsId: 'github-app',
                        usernameVariable: 'GIT_USER',
                        passwordVariable: 'GIT_TOKEN'
                    )]) {
                        sh '''
                            echo "=== Uploading release assets ==="
                            echo "Release ID: ${RELEASE_ID}"
                            echo "Version: ${NEW_VERSION}"

                            REPO="erauner/homelab-smoke"

                            # Upload each binary as a release asset
                            for binary in dist/smoke-*; do
                                FILENAME=$(basename "$binary")
                                echo "Uploading ${FILENAME}..."

                                curl -sSL \
                                    -X POST \
                                    -H "Authorization: token ${GIT_TOKEN}" \
                                    -H "Content-Type: application/octet-stream" \
                                    --data-binary @"$binary" \
                                    "https://uploads.github.com/repos/${REPO}/releases/${RELEASE_ID}/assets?name=${FILENAME}"

                                echo "  ✓ Uploaded ${FILENAME}"
                            done

                            echo "=== All assets uploaded ==="
                        '''
                    }
                }
            }
        }
    }

    post {
        success {
            echo """
            ✅ Build successful!

            Docker Image: ${env.IMAGE_NAME}:${env.VERSION}
            Release Tag: ${env.NEW_VERSION ?: 'N/A'}

            To pull image: docker pull ${env.IMAGE_NAME}:${env.VERSION}

            Standalone binaries available at:
            https://github.com/erauner/homelab-smoke/releases/tag/${env.NEW_VERSION}

            Quick install (macOS ARM64):
              curl -sSL https://github.com/erauner/homelab-smoke/releases/download/${env.NEW_VERSION}/smoke-darwin-arm64 -o smoke
              chmod +x smoke
              sudo mv smoke /usr/local/bin/
            """
        }
        failure {
            echo '❌ Build failed - check the logs'
        }
    }
}
