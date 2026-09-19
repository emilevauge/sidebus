plugins {
    alias(libs.plugins.android.application)
}

android {
    namespace = "app.sidebus"
    compileSdk = 36

    defaultConfig {
        applicationId = "app.sidebus"
        minSdk = 30
        targetSdk = 36
        // Same VERSION file as the Mac side: one number for both applications, and the
        // release that ships them carries that number as its tag.
        versionName = rootProject.file("../VERSION").readText().trim()
        versionCode = versionName!!.split(".").let { (it[0].toInt() * 10000) + (it[1].toInt() * 100) + it[2].toInt() }
    }

    // Release signing read from Gradle properties or the environment: no secret in the
    // repository. Without it, `assembleRelease` produces an unsigned APK.
    val storePath = (project.findProperty("sidebus.keystore") as String?)
        ?: System.getenv("SIDEBUS_KEYSTORE")

    signingConfigs {
        if (storePath != null) {
            create("release") {
                storeFile = file(storePath)
                storePassword = (project.findProperty("sidebus.keystorePassword") as String?)
                    ?: System.getenv("SIDEBUS_KEYSTORE_PASSWORD")
                keyAlias = (project.findProperty("sidebus.keyAlias") as String?)
                    ?: System.getenv("SIDEBUS_KEY_ALIAS") ?: "sidebus"
                keyPassword = (project.findProperty("sidebus.keyPassword") as String?)
                    ?: System.getenv("SIDEBUS_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            if (storePath != null) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    // Coroutines, and nothing else.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    testImplementation("junit:junit:4.13.2")
}
