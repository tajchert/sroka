// =============================================================================
// CORE:TESTING MODULE
//
// In-memory fakes of every core:domain interface, test data builders and
// MainDispatcherRule. Test-only: add it as testImplementation.
// =============================================================================

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kover)
}

android {
    namespace = "app.sroka.core.testing"
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
    api(projects.core.model)
    api(projects.core.domain)
    api(libs.androidx.paging.common)
    implementation(libs.kotlinx.coroutines.android)
    api(libs.kotlinx.coroutines.test)
    api(libs.junit)
    api(libs.turbine)
}
