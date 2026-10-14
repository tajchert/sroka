// =============================================================================
// CORE:DATASTORE MODULE
//
// Preferences DataStore for UserPreferences, the encrypted SessionStore and
// the install's deviceId (DECISIONS A6).
// =============================================================================

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.hilt)
    alias(libs.plugins.ksp)
    alias(libs.plugins.kover)
}

android {
    namespace = "app.sroka.core.datastore"
    compileSdk = libs.versions.compileSdk.get().toInt()

    defaultConfig {
        minSdk = libs.versions.minSdk.get().toInt()
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
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
}

dependencies {
    implementation(projects.core.model)
    implementation(projects.core.common)

    implementation(libs.hilt.android)
    ksp(libs.hilt.compiler)

    api(libs.datastore.preferences)
    implementation(libs.kotlinx.coroutines.android)

    testImplementation(libs.bundles.testing)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.ext.junit)
}
