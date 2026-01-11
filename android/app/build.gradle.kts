plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
	id("com.google.gms.google-services")
    id("org.jetbrains.kotlin.plugin.serialization")
}

dependencies {
	implementation(platform("com.google.firebase:firebase-bom:34.2.0"))
	implementation("com.google.firebase:firebase-analytics")
	// ADD THIS: Core library desugaring for flutter_local_notifications
	coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
}

android {
    namespace = "in.kilvish.android"
    compileSdk = 36  // Updated to 34 for better compatibility
    ndkVersion = "27.0.12077973"

    compileOptions {
        // ADD THIS: Enable desugaring
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "in.kilvish.android"
        minSdk = flutter.minSdkVersion
        targetSdk = 34  // Updated to 34 to match compileSdk
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // ADD THIS: Enable multidex if not already present
        multiDexEnabled = true
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}