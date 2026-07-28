import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 릴리즈 서명 정보(android/key.properties)를 읽는다. 파일이 있으면 릴리즈 키로 서명.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "kr.co.mychannel.meeting.prism"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // 앱 고유 패키지명(설치/Play Store 식별자) = namespace 와 동일.
        // 딥링크(App Links)의 assetlinks.json·intent:// 도 이 값을 사용.
        applicationId = "kr.co.mychannel.meeting.prism"
        // WebRTC(flutter_webrtc/livekit)는 minSdk 23 이상 필요
        minSdk = maxOf(23, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // 앱 표시 이름(매니페스트 android:label). 빌드 타입별로 덮어씀.
        manifestPlaceholders["appLabel"] = "Prism Meeting"
    }

    signingConfigs {
        create("release") {
            // key.properties 가 있을 때만 릴리즈 키 정보 로드
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // key.properties 있으면 릴리즈 키로 서명, 없으면 기존 debug 키(테스트용)
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
        // [feature/translation] debug 빌드는 별개 앱으로 설치되게 접미사를 붙인다.
        // → applicationId = ...prism.dev 라 릴리즈 앱과 한 기기에 공존(아이콘 2개).
        // release 빌드는 손대지 않으므로 main에 병합해도 프로덕션은 영향 없음.
        // 주의: .dev 는 별개 패키지라 딥링크(App Links/assetlinks)는 동작 안 함(번역 테스트엔 무관).
        debug {
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
            manifestPlaceholders["appLabel"] = "Prism 번역(dev)"
        }
    }
}

flutter {
    source = "../.."
}
