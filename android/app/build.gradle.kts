import java.util.Properties
import java.io.FileInputStream

val keyProperties = Properties()
val keyPropertiesFile = rootProject.file("key.properties")
if (keyPropertiesFile.exists()) {
    keyProperties.load(FileInputStream(keyPropertiesFile))
}

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
    namespace = "fyi.pocha.kilvish"
    compileSdk = 36  // Updated to 34 for better compatibility
    ndkVersion = "28.2.13676358"

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
        applicationId = "fyi.pocha.kilvish"
        minSdk = flutter.minSdkVersion
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // ADD THIS: Enable multidex if not already present
        multiDexEnabled = true
    }

    signingConfigs {
        create("release") {
            keyAlias = keyProperties["keyAlias"] as String
            keyPassword = keyProperties["keyPassword"] as String
            storeFile = file(keyProperties["storeFile"] as String)
            storePassword = keyProperties["storePassword"] as String
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

flutter {
    source = "../.."
}