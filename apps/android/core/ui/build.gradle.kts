// =============================================================================
// CORE:UI MODULE
//
// Shared Sroka UI pieces built on the design system: ItemRow, ItemThumbnail,
// OfflineBadge, TagChips, EmptyState and common strings (DECISIONS A2).
// =============================================================================

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.compose.compiler)
    alias(libs.plugins.screenshot)
    alias(libs.plugins.kover)
}

android {
    namespace = "app.sroka.core.ui"
    compileSdk = libs.versions.compileSdk.get().toInt()
    experimentalProperties["android.experimental.enableScreenshotTest"] = true

    defaultConfig {
        minSdk = libs.versions.minSdk.get().toInt()
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildFeatures {
        compose = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(projects.core.model)
    api(projects.core.designsystem)

    val composeBom = platform(libs.androidx.compose.bom)
    implementation(composeBom)
    implementation(libs.bundles.compose)
    implementation(libs.androidx.compose.material.icons.extended)
    debugImplementation(libs.bundles.compose.debug)
    implementation(libs.coil.compose)
    implementation(libs.androidx.activity.compose)

    testImplementation(libs.junit)

    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)

    screenshotTestImplementation(libs.screenshot.validation.api)
    screenshotTestImplementation(libs.androidx.compose.ui.tooling)
}
