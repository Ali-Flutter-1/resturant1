import java.util.Properties

// Signing credentials, kept out of the repository.
//
// `android/key.properties` is gitignored, as is the keystore it points at: an
// upload key in version control is an upload key anybody who clones this can
// publish with. Absent, the build falls back to the debug key below, so
// `flutter run --release` still works on a machine that has no keystore --
// what it must never do is produce something for Play signed that way.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.tscafe.app"
    // Pinned above Flutter's default: flutter_secure_storage is compiled
    // against 37, and Gradle warns on every build that compiling a library
    // against a higher SDK than the app is unsupported. Android SDKs are
    // backward compatible, so building against the highest any dependency
    // needs is the fix -- `targetSdk` is what governs runtime behaviour and is
    // left alone.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications uses java.time, which needs desugaring to
        // run on the API levels below 26 that minSdk still covers.
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // Must match the package_name in google-services.json, or Firebase
        // issues tokens this project cannot deliver to.
        applicationId = "com.tscafe.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            val path = keystoreProperties.getProperty("storeFile")
            if (path != null) {
                // Absolute paths are taken as given; a bare filename is looked
                // for in both of the places the convention puts it -- next to
                // this file (what Flutter's own template does) and in
                // `android/`. Getting this wrong reads as "wrong password",
                // because a missing keystore and a bad one fail alike, so a
                // path that resolves nowhere is called out by name instead.
                val candidates = listOf(file(path), project.file(path), rootProject.file(path))
                val found = candidates.firstOrNull { it.exists() }
                    ?: throw GradleException(
                        "key.properties points at a keystore that is not there: " +
                            "$path\nLooked in: " +
                            candidates.joinToString(", ") { it.absolutePath }
                    )

                storeFile = found
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // The real key when there is one, the debug key otherwise.
            //
            // The fallback is for local testing only. A Play upload signed with
            // the debug key is refused, and the build prints the warning below
            // rather than leaving somebody to discover that at the upload
            // screen.
            signingConfig = if (keystoreProperties.getProperty("storeFile") != null) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "WARNING: signing with the DEBUG key. Play will refuse this " +
                        "upload. Create android/key.properties to sign properly."
                )
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Required by the desugaring switch above.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
