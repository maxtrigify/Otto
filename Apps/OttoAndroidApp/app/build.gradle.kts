import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}
android {
    namespace = "io.openotto.android"
    compileSdk = 35

    defaultConfig {
        applicationId = "io.openotto.android"
        minSdk = 33
        targetSdk = 35
        versionCode = 2
        versionName = "0.1.1"
    }

    buildTypes {
        getByName("release") {
            isMinifyEnabled = false
            // Release signing intentionally stays unconfigured; debug APKs are
            // automatically signed by Android SDK for direct sideload testing.
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_21)
    }
}
