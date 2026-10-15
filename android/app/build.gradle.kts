plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.ppfriend.pp_friend"
    compileSdk = flutter.compileSdkVersion
    // 钉死而不是跟着 flutter.ndkVersion 走：tools/build_rust_android.sh 用这个
    // 版本的 libc++_shared.so，两边一旦漂移，构建期和运行期的 C++ 运行库就会
    // 悄悄错开 —— 那种崩溃报错信息离现场很远，很难查。
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.ppfriend.pp_friend"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // 写死 29（Android 10），不用 flutter.minSdkVersion（那是 24）。
        // 原因：上行音频是 Ogg Opus，而 Opus **编码器**和 MUXER_OUTPUT_OGG
        // 都要 API 29。24~28 没有编码器，只能发 WAV —— 但服务端规范只收
        // audio/ogg，发过去必然失败。与其留一个"看起来成功实际失败"的回落，
        // 不如把门槛提到 29。
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 只出 arm64-v8a。理由有两层：
        //  1. 我们只有这一个 ABI 的 .so —— 别的 ABI 上 librust_lib_pp_friend.so
        //     不存在，dlopen 会失败（会走到主界面的红色横幅，但那是白装一次）。
        //  2. 那个 .so 有 22MB（静态链了 ONNX Runtime 和 Silero 模型），
        //     出多个 ABI 会让 APK 白白胖三倍。
        //
        // **必须先 clear**：flutter-gradle-plugin 在它自己的 apply() 里已经塞进了
        // PLATFORM_ABI_LIST（arm/arm64/x64），而 apply() 在 plugins{} 那一刻就跑完了，
        // 早于本文件的 android{} 块。不 clear 只 += 的话等于什么都没做 ——
        // 这一点是实测出来的，不是推的。
        ndk {
            abiFilters.clear()
            abiFilters += "arm64-v8a"
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
