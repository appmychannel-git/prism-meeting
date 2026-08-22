import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Firebase(FCM/Firestore): android/app/google-services.json 을 읽는다.
    // 반드시 Flutter/Android 플러그인 뒤에 적용.
    id("com.google.gms.google-services")
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
        // flutter_local_notifications(수신벨 알림) 요구: 코어 라이브러리 디슈가링.
        isCoreLibraryDesugaringEnabled = true
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
        // App Links 딥링크 진입 경로. 브랜드마다 달라야 "그 브랜드 앱"으로만 열린다
        // (여러 브랜드가 같은 경로를 주장하면 어느 앱이 열릴지 불확정 → 선택창).
        // host는 공통, path는 flavor에서 /apps/meeting/<brand>/ 로 덮어씀.
        manifestPlaceholders["deepLinkHost"] = "androidtv.mychannel.co.kr"
        manifestPlaceholders["deepLinkPath"] = "/apps/meeting/prism/"
        // Firestore/Firebase 등 메서드 수가 많아 64K DEX 한계 회피.
        multiDexEnabled = true
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
            manifestPlaceholders["deepLinkPath"] = "/apps/meeting/prism/"
        }
        create("gbled") {
            dimension = "brand"
            applicationId = "kr.co.mychannel.meeting.gbled"
            manifestPlaceholders["appLabel"] = "Gbled Meeting"
            manifestPlaceholders["deepLinkPath"] = "/apps/meeting/gbled/"
        }
        create("viewplus") {
            dimension = "brand"
            applicationId = "kr.co.mychannel.meeting.viewplus"
            manifestPlaceholders["appLabel"] = " Viewplus Meeting"
            manifestPlaceholders["deepLinkPath"] = "/apps/meeting/viewplus/"
        }
        create("mychannel") {
            dimension = "brand"
            applicationId = "kr.co.mychannel.meeting"
            manifestPlaceholders["appLabel"] = "Mychannel Meeting"
            manifestPlaceholders["deepLinkPath"] = "/apps/meeting/mychannel/"
        }
        create("ecoglow") {
            dimension = "brand"
            applicationId = "kr.co.mychannel.meeting.ecoglowkc"
            manifestPlaceholders["appLabel"] = "ECO GLOW Meeting"
            manifestPlaceholders["deepLinkPath"] = "/apps/meeting/ecoglow/"
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
        // debug 빌드 표식(버전명에 -dev). applicationId 는 release 와 동일하게 둔다.
        // (FCM 은 각 applicationId 가 Firebase 에 등록돼야 하므로 .dev 접미사를 쓰지 않음.
        //  dev/release 동시설치가 필요하면 .dev 4개 패키지를 Firebase 에 추가 등록 후 접미사 복원.)
        debug {
            versionNameSuffix = "-dev"
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // 코어 라이브러리 디슈가링(flutter_local_notifications 요구).
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
