plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.example.host"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.example.host"
        minSdk        = 21
        targetSdk     = 34
        versionCode   = 1
        versionName   = "1.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { buildConfig = true }

    packaging {
        resources.excludes += "META-INF/**"
    }
}

dependencies {
    implementation("androidx.appcompat:appcompat:1.6.1")

    // Host app link UniTrack native TRỰC TIẾP từ JitPack. Đây là singleton
    // duy nhất trong process (:app + :unitrack-rn dùng cùng classloader).
    implementation("com.github.sieuvitdet:unitrack-sdk:0.3.37")

    // React Native — cùng version rn/package.json (0.75.4).
    implementation("com.facebook.react:react-android:0.75.4")
    implementation("com.facebook.react:hermes-android:0.75.4")

    // RN plugin module (bridge JS ↔ com.unitrack.sdk.UniTrack).
    // skipVendor=true → không kéo unitrack-sdk lần 2.
    implementation(project(":unitrack-rn"))
}
