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
        // 기본 applicationId(=namespace). 실제 값은 아래 브랜드 flavor에서 덮어씀.
        applicationId = "kr.co.mychannel.meeting.prism"
        // WebRTC(flutter_webrtc/livekit)는 minSdk 23 이상 필요
        minSdk = maxOf(23, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // 앱 표시 이름(매니페스트 android:label). flavor에서 브랜드별로 덮어씀.
        manifestPlaceholders["appLabel"] = "Prism Meeting"
    }

    // ── 브랜드(업체)별 flavor ── 한 코드베이스로 여러 브랜드 앱을 빌드.
    // 리소스(아이콘/스플래시)는 src/<flavor>/res 로 덮어쓴다.
    // 빌드 예: flutter build apk --release --flavor gbled --dart-define=APP_BRAND=글로벌전자
    flavorDimensions += "brand"
    productFlavors {
        create("prism") {
            dimension = "brand"
            applicationId = "kr.co.mychannel.meeting.prism"
            manifestPlaceholders["appLabel"] = "Prism Meeting"
        }
        create("gbled") {
            dimension = "brand"
            applicationId = "kr.co.mychannel.meeting.gbled"
            manifestPlaceholders["appLabel"] = "글로벌전자"
        }
        create("viewplus") {
            dimension = "brand"
            applicationId = "kr.co.mychannel.meeting.viewplus"
            manifestPlaceholders["appLabel"] = "뷰플러스"
        }
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
        // debug 빌드는 .dev 접미사로 릴리즈와 공존(같은 브랜드 debug↔release 동시설치).
        // 앱 이름은 flavor의 appLabel(브랜드명)을 그대로 사용. release는 손대지 않음.
        debug {
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
        }
    }
}

flutter {
    source = "../.."
}
