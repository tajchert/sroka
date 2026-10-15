// =============================================================================
// FEATURE:AUTH:API MODULE
//
// Public navigation keys of the auth feature (sign-in (email -> 6-digit code)).
// Other modules navigate to the feature through these keys only.
// =============================================================================

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.kover)
}

android {
    namespace = "app.sroka.feature.auth.api"
    compileSdk = libs.versions.compileSdk.get().toInt()

    defaultConfig {
        minSdk = libs.versions.minSdk.get().toInt()
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(libs.kotlinx.serialization.json)
    api(libs.androidx.navigation3.runtime)

    testImplementation(libs.junit)
}
