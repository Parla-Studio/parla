// Builds the Parla client apps: Android (APK) and desktop (Linux .deb, Windows setup.exe).
// The server lives in Parla-Studio/parla-server.
//
// The Linux package is published to the MirraNET APT repository (apt.mirranet.de) by the Publish stage: when
// APT_REPO names the reprepro repository directory (e.g. /var/www/apt, Manage Jenkins → System → Global
// properties), in the suite APT_SUITE (default "stable"); with APT_HOST (user@host) on another machine, reached
// with the SSH key of the Jenkins user. Only builds of main are published.
//
// The Windows installer (setup.exe) is built right here on Linux with NSIS: the build machine needs
// `apt install nsis unzip`. Optionally a .msi can be built as well: set the environment variable
// PARLA_WINDOWS_AGENT (e.g. in the job or globally) to the label of a Windows agent with a JDK 17-21.
pipeline {
    agent any
    options { buildDiscarder(logRotator(numToKeepStr: '20')) }

    stages {
        stage('Android') {
            steps {
                dir('android') {
                    // Provides a JDK Gradle can run on (17-24) and the Android SDK (installed on first run).
                    sh '''
                        chmod +x gradlew scripts/setup-android-sdk.sh
                        scripts/setup-android-sdk.sh > .build-env
                        . ./.build-env
                        ./gradlew --no-daemon testDebugUnitTest assembleRelease
                    '''
                }
            }
            post {
                always { junit allowEmptyResults: true, testResults: 'android/app/build/test-results/**/*.xml' }
                success { archiveArtifacts artifacts: 'android/app/build/outputs/apk/release/*.apk', fingerprint: true }
            }
        }

        stage('Desktop Linux') {
            steps {
                dir('desktop') {
                    // JDK 17-21 (downloaded on first run if needed); jpackage needs dpkg-deb + fakeroot.
                    sh '''
                        chmod +x gradlew scripts/setup-jdk.sh packaging/apt/*.sh
                        scripts/setup-jdk.sh > .build-env
                        . ./.build-env
                        # The workspace is kept between builds, so packages of earlier builds must not be left over.
                        rm -f build/dist/*.deb
                        ./gradlew --no-daemon distDeb
                        # Every build gets its own package version, newer than the one before, so apt sees it as
                        # an update even while the app keeps the same version: 1.3.0+202611142030.gitabc1234
                        # (only the .deb's Version field; the version inside the app stays 1.3.0).
                        VERSION="$(sed -n 's/^val appVersion = "\\(.*\\)"$/\\1/p' build.gradle.kts | head -n 1)"
                        COMMIT="$(git rev-parse --short=7 HEAD 2>/dev/null || echo local)"
                        DEB_VERSION="$VERSION+$(date -u +%Y%m%d%H%M).git$COMMIT"
                        for deb in build/dist/*.deb; do packaging/apt/set-deb-version.sh "$deb" "$DEB_VERSION"; done
                    '''
                }
            }
            post {
                success { archiveArtifacts artifacts: 'desktop/build/dist/*.deb', fingerprint: true }
            }
        }

        stage('Publish') {
            // Adds the Linux package (Debian package name "parla") to the MirraNET APT repository.
            when {
                expression { env.APT_REPO?.trim() && (env.BRANCH_NAME == null || env.BRANCH_NAME == 'main') }
            }
            steps {
                dir('desktop') {
                    script {
                        if (env.APT_HOST?.trim()) {
                            // Repository on another machine: copy the packages and the script there and
                            // run it with that machine's reprepro and signing key.
                            sh '''
                                set -eu
                                tmp=$(ssh -o BatchMode=yes "$APT_HOST" mktemp -d)
                                scp -o BatchMode=yes -q packaging/apt/publish.sh build/dist/*.deb "$APT_HOST:$tmp/"
                                ssh -o BatchMode=yes "$APT_HOST" bash -s -- "$tmp" "$APT_REPO" "${APT_SUITE:-stable}" <<'EOF'
rc=0
bash "$1/publish.sh" "$2" "$3" "$1"/*.deb || rc=$?
rm -rf "$1"
exit $rc
EOF
                            '''
                        } else {
                            sh 'packaging/apt/publish.sh "$APT_REPO" "${APT_SUITE:-stable}" build/dist/*.deb'
                        }
                    }
                }
            }
        }

        stage('Desktop Windows') {
            steps {
                dir('desktop') {
                    // Windows installer built on Linux: app + Windows libraries + bundled Windows Java runtime,
                    // packed with NSIS (makensis). The Windows JRE is downloaded once into ~/jdks.
                    sh '''
                        chmod +x gradlew scripts/setup-jdk.sh scripts/build-windows-installer.sh
                        scripts/setup-jdk.sh > .build-env
                        . ./.build-env
                        ./gradlew --no-daemon distWindows
                    '''
                }
            }
            post {
                success { archiveArtifacts artifacts: 'desktop/build/dist/*.exe', fingerprint: true }
            }
        }

        stage('Desktop Windows MSI') {
            when { beforeAgent true; expression { env.PARLA_WINDOWS_AGENT?.trim() } }
            agent { label "${env.PARLA_WINDOWS_AGENT}" }
            steps {
                dir('desktop') {
                    bat 'gradlew.bat --no-daemon distMsi'
                }
            }
            post {
                success { archiveArtifacts artifacts: 'desktop/build/dist/*.msi', fingerprint: true }
            }
        }
    }
}
