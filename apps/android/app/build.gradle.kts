// =============================================================================
// APP MODULE
// =============================================================================
// The application module that ties everything together.
//
// ## Responsibilities
//
// - Application class with Hilt setup
// - MainActivity as single entry point
// - Navigation host combining all features
// - Theme observation and application
//
// ## Dependency Approach
//
// This module depends on:
// - All feature:*:impl modules (to access navigation entries)
// - core:designsystem (for theme)
// - core:data (implementations of core:domain interfaces, workers)
// - core:model / core:domain (preferences, session state)
//
// Features are composed here via their navigation contributions.
// =============================================================================

import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.compose.compiler)
    alias(libs.plugins.screenshot)
    alias(libs.plugins.hilt)
    alias(libs.plugins.ksp)
    alias(libs.plugins.kover)
    alias(libs.plugins.baselineprofile)
}

// Release signing. Values come from keystore.properties (local, gitignored) or
// SROKA_* environment variables (CI). The keystore itself is private and never
// committed; see docs/RELEASING.md.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("keystore.properties")
    if (file.exists()) {
        file.inputStream().use(::load)
    }
}

fun releaseSigningValue(property: String, envVar: String): String? =
    keystoreProperties.getProperty(property) ?: System.getenv(envVar)

fun requiredReleaseSigningValue(property: String, envVar: String): String =
    releaseSigningValue(property, envVar)
        ?: error("Release signing is configured, but $property/$envVar is missing.")

val releaseStorePath = releaseSigningValue("storeFile", "SROKA_KEYSTORE_PATH")

android {
    namespace = "app.sroka"
    compileSdk = libs.versions.compileSdk.get().toInt()
    experimentalProperties["android.experimental.enableScreenshotTest"] = true

    defaultConfig {
        applicationId = "app.sroka"
        minSdk = libs.versions.minSdk.get().toInt()
        targetSdk = libs.versions.targetSdk.get().toInt()
        versionCode = 3
        versionName = "1.1.1"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables {
            useSupportLibrary = true
        }
        // Server used until the user overrides it in Settings (DECISIONS A5).
        buildConfigField("String", "DEFAULT_SERVER_URL", "\"https://api.sroka.app\"")
    }

    signingConfigs {
        if (releaseStorePath != null) {
            create("release") {
                storeFile = rootProject.file(releaseStorePath)
                storePassword = requiredReleaseSigningValue(
                    "storePassword",
                    "SROKA_KEYSTORE_PASSWORD",
                )
                keyAlias = requiredReleaseSigningValue("keyAlias", "SROKA_KEY_ALIAS")
                keyPassword = requiredReleaseSigningValue(
                    "keyPassword",
                    "SROKA_KEY_PASSWORD",
                )
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            // Falls back to the debug key when no release keystore is configured,
            // so contributor and CI release builds stay installable. Published
            // builds are verified against the release certificate.
            signingConfig = if (releaseStorePath != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
        // Preserve release optimizations when customizing the measured variant.
        // The profile plugin configures debuggability and profileability.
        create("benchmarkRelease") {
            initWith(getByName("release"))
            signingConfig = signingConfigs.getByName("debug")
        }
        create("nonMinifiedRelease") {
            signingConfig = signingConfigs.getByName("debug")
        }
        debug {
            isDebuggable = true
            applicationIdSuffix = ".debug"
            // Local wrangler dev server via `adb reverse tcp:8787 tcp:8787`.
            buildConfigField("String", "DEFAULT_SERVER_URL", "\"http://localhost:8787\"")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    testOptions {
        unitTests {
            // Robolectric needs real resources; the JDK opens are required
            // because Robolectric reaches into internals closed since Java 17.
            isIncludeAndroidResources = true
            all {
                it.jvmArgs(
                    "--add-opens=java.base/java.io=ALL-UNNAMED",
                    "--add-opens=java.base/java.lang=ALL-UNNAMED",
                    "--add-exports=java.base/jdk.internal.access=ALL-UNNAMED",
                )
            }
        }
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

baselineProfile {
    automaticGenerationDuringBuild = false
    saveInSrc = true
    mergeIntoMain = true
}

dependencies {
    baselineProfile(projects.benchmark)
    implementation(libs.androidx.profileinstaller)
    // Project modules
    implementation(projects.feature.auth.impl)
    implementation(projects.feature.library.impl)
    implementation(projects.feature.reader.impl)
    implementation(projects.feature.settings.impl)
    implementation(projects.core.designsystem)
    implementation(projects.core.model)
    implementation(projects.core.common)
    implementation(projects.core.domain)
    // Real implementations of the core:domain interfaces, workers, Room, network, DataStore.
    implementation(projects.core.data)
    implementation(projects.core.ui)

    // Android Core
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.core.splashscreen)

    // Compose BOM
    val composeBom = platform(libs.androidx.compose.bom)
    implementation(composeBom)
    implementation(libs.bundles.compose)
    implementation(libs.androidx.compose.material3.navigation.suite)
    debugImplementation(libs.bundles.compose.debug)

    // Lifecycle
    implementation(libs.bundles.lifecycle)

    // Navigation 3
    implementation(libs.bundles.navigation3)

    // Material 3 adaptive list-detail scenes
    implementation(libs.bundles.adaptive)

    // Hilt
    implementation(libs.hilt.android)
    ksp(libs.hilt.compiler)
    implementation(libs.androidx.hilt.lifecycle.viewmodel.compose)

    // Background sync/downloads (WorkManager with Hilt-injected workers)
    implementation(libs.androidx.work.runtime.ktx)
    implementation(libs.androidx.hilt.work)
    ksp(libs.androidx.hilt.compiler)
    implementation(libs.androidx.lifecycle.process)
    implementation(libs.androidx.webkit)

    // Coroutines
    implementation(libs.kotlinx.coroutines.android)

    // Testing
    screenshotTestImplementation(libs.screenshot.validation.api)
    screenshotTestImplementation(libs.androidx.compose.ui.tooling)
    testImplementation(libs.junit)
    testImplementation(projects.core.testing)

    // Navigation and deep link tests drive the real Activity locally through
    // Robolectric, with Hilt supplying the real object graph.
    testImplementation(composeBom)
    testImplementation(libs.bundles.testing.robolectric)
    testImplementation(libs.androidx.compose.ui.test.manifest)
    testImplementation(libs.hilt.android.testing)
    kspTest(libs.hilt.compiler)
    androidTestImplementation(composeBom)
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.espresso.core)
}
