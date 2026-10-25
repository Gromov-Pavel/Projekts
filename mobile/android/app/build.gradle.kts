import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Keep signing material outside the repository; never silently sign a release as debug.
val releasePropertiesPath = providers.environmentVariable("IPSC_SIGNING_PROPERTIES").orNull
val releaseProperties = releasePropertiesPath?.let { path ->
    Properties().apply { file(path).inputStream().use { load(it) } }
}
if (gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) } && releaseProperties == null) {
    throw GradleException("Set IPSC_SIGNING_PROPERTIES to the private release signing properties file")
}

// Also cover aggregate tasks such as `build` that pull in release packaging.
gradle.taskGraph.whenReady {
    if (releaseProperties == null && allTasks.any {
        it.project.path == project.path && it.name in setOf("packageRelease", "signReleaseBundle")
    }) {
        throw GradleException("Release packaging requires IPSC_SIGNING_PROPERTIES")
    }
}

android {
    namespace = "app.pace.ipsc_training"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.pace.ipsc_training"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseProperties != null) {
            create("ipscRelease") {
                storeFile = file(requireNotNull(releaseProperties.getProperty("storeFile")))
                storePassword = requireNotNull(releaseProperties.getProperty("storePassword"))
                keyAlias = requireNotNull(releaseProperties.getProperty("keyAlias"))
                keyPassword = requireNotNull(releaseProperties.getProperty("keyPassword"))
            }
        }
    }
    buildTypes {
        release {
            isDebuggable = false
            isJniDebuggable = false
            signingConfig = signingConfigs.findByName("ipscRelease")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// Keep the editor and video_player_android on one binary-compatible Media3 release.
val media3Version = "1.9.2"
configurations.configureEach {
    resolutionStrategy.eachDependency {
        if (requested.group == "androidx.media3") {
            useVersion(media3Version)
            because("Match video_player_android across compile, runtime and instrumentation")
        }
    }
}

dependencies {
    implementation("androidx.media3:media3-transformer:$media3Version")
    implementation("androidx.media3:media3-effect:$media3Version")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:core:1.6.1")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}
