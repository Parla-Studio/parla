// Builds the Parla client apps: Android (APK), desktop (Linux .deb, Windows setup.exe) and iOS (unsigned .ipa
// and a simulator build).
// The server lives in Parla-Studio/parla-server.
//
// Releases of the Linux package – including the upload to the MirraNET APT repository (apt.mirranet.de) – are
// made by GitHub Actions (Actions › Release › Run workflow); Jenkins only builds test packages.
//
// The Windows installer (setup.exe) is built right here on Linux with NSIS: the build machine needs
// `apt install nsis unzip`. Optionally a .msi can be built as well: set the environment variable
// PARLA_WINDOWS_AGENT (e.g. in the job or globally) to the label of a Windows agent with a JDK 17-21.
//
// The iOS app is built on the macOS node with Xcode, "Spark" by default (another label via PARLA_IOS_AGENT).
// It needs Xcode with the iOS platform installed; XcodeGen is downloaded by ios/scripts/build-ios.sh.
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
                        chmod +x gradlew scripts/setup-jdk.sh
                        scripts/setup-jdk.sh > .build-env
                        . ./.build-env
                        # The workspace is kept between builds, so packages of earlier builds must not be left over.
                        rm -f build/dist/*.deb
                        ./gradlew --no-daemon distDeb
                    '''
                }
            }
            post {
                success { archiveArtifacts artifacts: 'desktop/build/dist/*.deb', fingerprint: true }
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

        stage('iOS') {
            agent { label "${env.PARLA_IOS_AGENT ?: 'Spark'}" }
            steps {
                dir('ios') {
                    // XcodeGen project, ParlaCore unit tests, unsigned device build (.ipa) and simulator build.
                    sh 'chmod +x scripts/build-ios.sh && scripts/build-ios.sh'
                }
            }
            post {
                success { archiveArtifacts artifacts: 'ios/build/dist/*', fingerprint: true }
            }
        }
    }
}
