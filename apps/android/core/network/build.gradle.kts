// =============================================================================
// CORE:NETWORK MODULE
//
// Hand-written OkHttp + kotlinx.serialization client `SrokaApi` and its DTOs
// (DECISIONS A5). No Retrofit.
// =============================================================================

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.hilt)
    alias(libs.plugins.ksp)
    alias(libs.plugins.kover)
}

android {
    namespace = "app.sroka.core.network"
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
    implementation(projects.core.model)
    implementation(projects.core.common)

    implementation(libs.hilt.android)
    ksp(libs.hilt.compiler)

    api(libs.okhttp)
    api(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)

    testImplementation(libs.bundles.testing)
    testImplementation(libs.okhttp.mockwebserver3)
}
