pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionMode(RepositoriesMode.PREFER_SETTINGS)
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
    }
}

rootProject.name = "UniTrackRNHost"
include(":app")

// RN plugin từ monorepo. skipVendor được set ở gradle.properties → RN plugin
// đổi UniTrack SDK dep thành `compileOnly`, host app supply thật.
include(":unitrack-rn")
project(":unitrack-rn").projectDir = file("../../../react-native/android")

// RN autolinking (0.75) đọc PackageList từ file gen sẵn. Với setup manual
// này em skip autolink, khai báo tay RNUniTrackPackage trong MainApplication.
