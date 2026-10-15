// =============================================================================
// CORE:DOMAIN MODULE
//
// Interfaces consumed by features (DECISIONS A2): repositories, sync control,
// content store, auth, settings and account. No implementations live here -
// core:data provides them and core:testing provides fakes.
// =============================================================================

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kover)
}

android {
    namespace = "app.sroka.core.domain"
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
    api(libs.androidx.paging.common)
    api(libs.kotlinx.coroutines.android)

    testImplementation(libs.junit)
}
