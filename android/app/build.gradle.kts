plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
	id("com.google.gms.google-services")
}

dependencies {
	implementation(platform("com.google.firebase:firebase-bom:34.2.0"))
	implementation("com.google.firebase:firebase-analytics")
	// ADD THIS: Core library desugaring for flutter_local_notifications
	coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}

android {
    namespace = "in.kilvish.android"
    compileSdk = 36  // Updated to 34 for better compatibility
    ndkVersion = "27.0.12077973"

    compileOptions {
        // ADD THIS: Enable desugaring
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
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