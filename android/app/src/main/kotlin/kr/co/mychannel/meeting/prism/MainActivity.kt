package kr.co.mychannel.meeting.prism

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.database.Cursor
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import java.io.ByteArrayInputStream
import java.net.NetworkInterface
import java.security.MessageDigest
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import javax.security.auth.x500.X500Principal
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.view.WindowManager
import com.kakao.sdk.auth.model.OAuthToken
import com.kakao.sdk.common.KakaoSdk
import com.kakao.sdk.common.model.ClientError
import com.kakao.sdk.common.model.ClientErrorCause
import com.kakao.sdk.user.UserApiClient
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

class MainActivity : FlutterActivity() {
    private val channelName = "app/fullscreen"
    private var proximityLock: PowerManager.WakeLock? = null

    // ===== 마켓앱 로그인 연동(안드로이드TV) =====
    private val storeChannelName = "app/store_login"
    // 브랜드 공통 고정 authority(§2-5). 마켓 패키지명은 브랜드마다 다르므로 쓰지 않는다.
    private val storeAuthority = "kr.co.viewplus.market.session"
    private val sessionUri: Uri = Uri.parse("content://$storeAuthority")
    private val verifyUrl = "https://viewplus.co.kr/api/tv/session"
    private var storeChannel: MethodChannel? = null
    private var sessionObserver: ContentObserver? = null

    // ===== 카카오 로그인(모바일 자체 로그인) =====
    // 브랜드(flavor)별 키 — build.gradle.kts 의 kakaoKey(...) 가 리소스로 넣는다.
    private val kakaoNativeKey by lazy { getString(R.string.kakao_native_key) }
    private var kakaoInited = false

    // 수신 통화(풀스크린 인텐트)가 잠금화면 위로 뜨고 화면을 켜도록.
    // 매니페스트의 showWhenLocked/turnScreenOn(API 27+)에 더해, 구버전(23~26)은
    // 창 플래그로 동일 동작을 보장한다.
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Android 14+(API 34)에서 풀스크린 통화 알림 사용 가능 여부.
                    "canUseFullScreenIntent" -> {
                        if (Build.VERSION.SDK_INT >= 34) {
                            val nm = getSystemService(Context.NOTIFICATION_SERVICE)
                                as NotificationManager
                            result.success(nm.canUseFullScreenIntent())
                        } else {
                            result.success(true)
                        }
                    }
                    // 재설치해도 유지되는 기기 신원(ANDROID_ID). (앱 서명키+기기 기준,
                    // 공장초기화 시에만 변경) → 회원 없이 안정적 식별.
                    "getAndroidId" -> {
                        try {
                            val id = Settings.Secure.getString(
                                contentResolver,
                                Settings.Secure.ANDROID_ID,
                            )
                            result.success(id)
                        } catch (e: Exception) {
                            result.success(null)
                        }
                    }
                    // 기기 식별값(제조사/모델/보드). 카메라 센서 방향을 틀리게
                    // 보고하는 특정 기기(상하 반전)를 Dart에서 가려내는 데 쓴다.
                    "getDeviceInfo" -> {
                        result.success(
                            mapOf(
                                "manufacturer" to Build.MANUFACTURER,
                                "model" to Build.MODEL,
                                "board" to Build.BOARD,
                                "device" to Build.DEVICE,
                            )
                        )
                    }
                    // CS 진단용 기기·앱 정보 한 묶음(서명키·펌웨어·시리얼·네트워크 포함).
                    "deviceReport" -> result.success(deviceReport())
                    // 서명 라벨만 가볍게(지원 기기 팝업의 "이 기기" 뒤 (R)/(C) 표기).
                    "signLabel" -> result.success(signatureLabel())
                    // 화면 최단변 dp(브랜드 스플래시 판별용). Flutter 첫 프레임 MediaQuery 는
                    // 부정확할 수 있어, 네이티브 DisplayMetrics(밀도 변경 반영)로 정확히 준다.
                    "screenShortestDp" -> {
                        val dm = resources.displayMetrics
                        val dp = (minOf(dm.widthPixels, dm.heightPixels) / dm.density).toInt()
                        result.success(dp)
                    }
                    // 강제/권장 업데이트: 주어진 주소 or 자기 패키지의 스토어 열기.
                    "openUrl" -> { openUrl(call.argument<String>("url") ?: ""); result.success(true) }
                    "openStore" -> { openUrl("market://details?id=$packageName"); result.success(true) }
                    // 해당 앱의 "전체 화면 알림 허용" 설정 화면으로 이동.
                    "openFullScreenSettings" -> {
                        try {
                            if (Build.VERSION.SDK_INT >= 34) {
                                val i = Intent(
                                    Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                                    Uri.parse("package:$packageName"),
                                )
                                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                startActivity(i)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    // 음성통화 시 귀에 대면 화면 끄기(근접센서 wake lock).
                    "acquireProximityLock" -> {
                        try {
                            val pm = getSystemService(Context.POWER_SERVICE)
                                as PowerManager
                            @Suppress("DEPRECATION")
                            if (pm.isWakeLockLevelSupported(
                                    PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) {
                                if (proximityLock == null) {
                                    proximityLock = pm.newWakeLock(
                                        PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
                                        "prism:call")
                                }
                                if (proximityLock?.isHeld != true) {
                                    proximityLock?.acquire(60 * 60 * 1000L)
                                }
                                result.success(true)
                            } else {
                                result.success(false)
                            }
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "releaseProximityLock" -> {
                        try {
                            if (proximityLock?.isHeld == true) {
                                proximityLock?.release()
                            }
                        } catch (e: Exception) {
                        }
                        result.success(true)
                    }
                    // CCTV 송출 전 카메라 사용 가능 여부 사전검사(백그라운드 스레드).
                    // 반환: "ok"(열림) | "none"(카메라 0개) | "blocked"(열기 실패) |
                    //       "timeout"(제한시간 내 콜백 없음) | "unknown"(권한없음/판단보류).
                    // 메인스레드를 막지 않으므로, 카메라 없는 기기에서도 Flutter가 멈추지 않고
                    // 바로 "카메라 없음" 안내를 띄울 수 있다. (setCameraEnabled 직접 호출은
                    // phantom-camera 기기에서 메인스레드를 블록해 멈춘다)
                    "probeCamera" -> {
                        val timeoutMs = call.argument<Int>("timeoutMs") ?: 5000
                        Thread {
                            val res = probeCamera(timeoutMs)
                            runOnUiThread { result.success(res) }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }

        // 마켓앱 로그인 세션 채널.
        storeChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, storeChannelName)
        storeChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                // 마켓 provider에서 로그인 세션 한 줄을 읽는다.
                // 반환: Map(마켓 있음) / null(마켓 없음·서명키 불일치).
                "read" -> result.success(readSession())
                // 토큰이 서버에서 유효한지 확인(GET /api/tv/session). HTTP 상태코드 반환
                // (200=로그인, 401=끊김, -1=네트워크오류). 메인스레드 밖에서 실행.
                "verify" -> {
                    val token = call.argument<String>("token") ?: ""
                    Thread {
                        val code = verifySession(token)
                        runOnUiThread { result.success(code) }
                    }.start()
                }
                // 같은 기기 마켓앱의 versionCode(정책 API 전송용). 없으면 0.
                "marketVersionCode" -> result.success(marketVersionCode())
                // 마켓 로그인 화면을 연다(끝나면 return 패키지로 자동 복귀).
                "openStoreLogin" -> result.success(openStoreLogin())
                // 마켓 로그아웃 감지(마켓이 notifyChange를 쏜다) → onSessionChanged 콜백.
                "startObserve" -> result.success(startObserve())
                "stopObserve" -> result.success(stopObserve())
                else -> result.notImplemented()
            }
        }

        // 카카오 로그인: access_token 을 받아 Dart(서버)로 넘긴다.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app/kakao")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "login" -> kakaoLogin(result)
                    else -> result.notImplemented()
                }
            }
    }

    // 카카오톡(설치 시) → 카카오계정 폴백. 성공 시 access_token, 취소 시 "cancelled".
    private fun kakaoLogin(result: MethodChannel.Result) {
        try {
            if (!kakaoInited) {
                KakaoSdk.init(this, kakaoNativeKey)
                kakaoInited = true
            }
        } catch (e: Exception) {
            result.error("kakao", "init failed: ${e.message}", null)
            return
        }
        val resolved = AtomicBoolean(false)
        fun ok(token: String) {
            if (resolved.compareAndSet(false, true)) result.success(token)
        }
        fun cancelled() {
            if (resolved.compareAndSet(false, true)) {
                result.error("cancelled", "user cancelled", null)
            }
        }
        fun fail(msg: String?) {
            if (resolved.compareAndSet(false, true)) {
                result.error("kakao", msg ?: "login failed", null)
            }
        }

        val accountCb: (OAuthToken?, Throwable?) -> Unit = { token, error ->
            when {
                error != null -> {
                    if (error is ClientError &&
                        error.reason == ClientErrorCause.Cancelled) {
                        cancelled()
                    } else {
                        fail(error.message)
                    }
                }
                token != null -> ok(token.accessToken)
                else -> fail("no token")
            }
        }

        if (UserApiClient.instance.isKakaoTalkLoginAvailable(this)) {
            UserApiClient.instance.loginWithKakaoTalk(this) { token, error ->
                if (error != null) {
                    if (error is ClientError &&
                        error.reason == ClientErrorCause.Cancelled) {
                        cancelled()
                    } else {
                        // 카카오톡 로그인 실패 → 카카오계정(웹)으로 폴백
                        UserApiClient.instance
                            .loginWithKakaoAccount(this, callback = accountCb)
                    }
                } else if (token != null) {
                    ok(token.accessToken)
                } else {
                    fail("no token")
                }
            }
        } else {
            UserApiClient.instance.loginWithKakaoAccount(this, callback = accountCb)
        }
    }

    // 카메라를 백그라운드에서 실제로 열어보고 결과를 돌려준다(메인스레드 비차단).
    private fun probeCamera(timeoutMs: Int): String {
        return try {
            if (checkSelfPermission(android.Manifest.permission.CAMERA)
                != PackageManager.PERMISSION_GRANTED) {
                return "unknown" // 권한 없음 → 판단 보류(Dart에서 기존 경로)
            }
            val cm = getSystemService(Context.CAMERA_SERVICE) as CameraManager
            val ids = cm.cameraIdList
            if (ids.isEmpty()) return "none" // 카메라 0개(진짜 없음)
            val latch = CountDownLatch(1)
            val opened = AtomicBoolean(false)
            val deviceRef = AtomicReference<CameraDevice?>(null)
            val ht = HandlerThread("camProbe").apply { start() }
            val handler = Handler(ht.looper)
            try {
                cm.openCamera(ids[0], object : CameraDevice.StateCallback() {
                    override fun onOpened(c: CameraDevice) {
                        deviceRef.set(c); opened.set(true); latch.countDown()
                    }
                    override fun onDisconnected(c: CameraDevice) {
                        try { c.close() } catch (_: Exception) {}; latch.countDown()
                    }
                    override fun onError(c: CameraDevice, error: Int) {
                        try { c.close() } catch (_: Exception) {}; latch.countDown()
                    }
                }, handler)
            } catch (e: Exception) {
                try { ht.quitSafely() } catch (_: Exception) {}
                return "blocked"
            }
            val done = latch.await(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
            try { deviceRef.get()?.close() } catch (_: Exception) {}
            try { ht.quitSafely() } catch (_: Exception) {}
            if (!done) "timeout" else if (opened.get()) "ok" else "blocked"
        } catch (e: Exception) {
            "unknown"
        }
    }

    // 같은 기기 마켓앱의 versionCode. provider authority 로 패키지를 찾아 조회
    // (패키지명이 브랜드마다 달라 하드코딩하지 않는다). 못 읽으면 0.
    private fun marketVersionCode(): Long {
        return try {
            val pi = packageManager.resolveContentProvider(storeAuthority, 0)
                ?: return 0L
            val info = packageManager.getPackageInfo(pi.packageName, 0)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                info.longVersionCode
            } else {
                @Suppress("DEPRECATION") info.versionCode.toLong()
            }
        } catch (e: Exception) {
            0L
        }
    }

    // ===== CS 진단용 기기·앱 정보(서명키·펌웨어·시리얼·네트워크 포함) =====
    // 외부 주소 열기(업데이트 안내). market:// 가 안 열리면 https 플레이스토어로 폴백.
    private fun openUrl(url: String) {
        if (url.isEmpty()) return
        try {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: Exception) {
            if (url.startsWith("market://")) {
                val id = Uri.parse(url).getQueryParameter("id") ?: return
                runCatching {
                    startActivity(Intent(Intent.ACTION_VIEW,
                        Uri.parse("https://play.google.com/store/apps/details?id=$id"))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                }
            }
        }
    }

    private fun deviceReport(): Map<String, Any?> {
        val dm = resources.displayMetrics
        val (netType, internetOk) = networkStatus()
        return mapOf(
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "device" to "${Build.MANUFACTURER}_${Build.MODEL}".replace(" ", "_"),
            "firmwareModel" to firmwareModel(),
            "hwSerial" to hwSerial(),
            "buildId" to Build.DISPLAY,
            "androidVersion" to "${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
            "screen" to "${dm.widthPixels}x${dm.heightPixels} / ${dm.densityDpi}dpi",
            "androidId" to runCatching {
                Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
            }.getOrNull(),
            "sign" to signatureLabel(),
            "signHash" to signatureHash(),
            "network" to netType,
            "internetOk" to internetOk,
            "localIp" to localIp(),
            "marketVersionCode" to marketVersionCode(),
        )
    }

    private fun firmwareModel(): String? = runCatching {
        val cls = Class.forName("android.os.SystemProperties")
        val get = cls.getMethod("get", String::class.java)
        (get.invoke(null, "persist.sys.lz.MODEL") as? String)?.takeIf { it.isNotEmpty() }
    }.getOrNull()

    private fun hwSerial(): String = runCatching {
        val s = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Build.getSerial()
        } else {
            @Suppress("DEPRECATION") Build.SERIAL
        }
        if (s.isNotEmpty() && s != Build.UNKNOWN) s else serialFromProp()
    }.getOrElse { serialFromProp() }

    private fun serialFromProp(): String = runCatching {
        val cls = Class.forName("android.os.SystemProperties")
        val get = cls.getMethod("get", String::class.java)
        (get.invoke(null, "ro.serialno") as? String)?.takeIf { it.isNotEmpty() } ?: "-"
    }.getOrDefault("-")

    private fun networkStatus(): Pair<String, Boolean> = runCatching {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val n = cm.activeNetwork ?: return Pair("없음", false)
        val cap = cm.getNetworkCapabilities(n) ?: return Pair("없음", false)
        val type = when {
            cap.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "Wi-Fi"
            cap.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "이더넷"
            cap.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "모바일"
            else -> "연결됨"
        }
        Pair(type, cap.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED))
    }.getOrDefault(Pair("확인 불가", false))

    private fun localIp(): String = runCatching {
        NetworkInterface.getNetworkInterfaces().asSequence()
            .flatMap { it.inetAddresses.asSequence() }
            .firstOrNull { !it.isLoopbackAddress && it.hostAddress?.contains(':') == false }
            ?.hostAddress ?: "-"
    }.getOrDefault("-")

    // ── 서명키: 실행 중 자기 인증서를 읽어 라벨/해시 판정(재서명당해도 사실을 보고) ──
    private val pinnedSigns = mapOf(
        "fd12b5fe8e80fc7b32cd51149117eecf430f3097a873ba53a718505fbaef6d60" to "rumpus",
        "1c817acdb142d9dc0d4b471a2057f6a95ddd625655f90d1c519d7fe5e9c81682" to "cubot",
    )
    private var cachedCertDer: ByteArray? = null
    private var cachedCertHash: String? = null

    private fun signatureHash(): String = selfCertHash() ?: ""

    private fun signatureLabel(): String {
        val h = selfCertHash() ?: return "unknown"
        return pinnedSigns[h] ?: certOrg() ?: "unknown"
    }

    private fun selfCertHash(): String? {
        cachedCertHash?.let { return it }
        val der = selfCertDer() ?: return null
        val h = MessageDigest.getInstance("SHA-256").digest(der)
            .joinToString("") { "%02x".format(it) }
        cachedCertHash = h
        return h
    }

    private fun selfCertDer(): ByteArray? {
        cachedCertDer?.let { return it }
        return runCatching {
            val pm = packageManager
            val der = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val s = pm.getPackageInfo(
                    packageName, PackageManager.GET_SIGNING_CERTIFICATES).signingInfo
                (if (s != null && s.hasMultipleSigners()) s.apkContentsSigners
                else s?.apkContentsSigners)?.firstOrNull()?.toByteArray()
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(packageName, PackageManager.GET_SIGNATURES)
                    .signatures?.firstOrNull()?.toByteArray()
            }
            cachedCertDer = der
            der
        }.getOrNull()
    }

    // 인증서 소유자 O=(없으면 CN=/OU=)를 소문자 영숫자 라벨로.
    private fun certOrg(): String? = runCatching {
        val der = selfCertDer() ?: return null
        val cert = CertificateFactory.getInstance("X.509")
            .generateCertificate(ByteArrayInputStream(der)) as X509Certificate
        val dn = cert.subjectX500Principal.getName(X500Principal.RFC2253)
        val parts = dn.split(Regex("""(?<!\\),"""))
        listOf("O=", "CN=", "OU=").firstNotNullOfOrNull { key ->
            parts.firstNotNullOfOrNull { part ->
                part.trim().takeIf { it.startsWith(key, ignoreCase = true) }
                    ?.substring(key.length)
                    ?.replace("\\", "")?.lowercase()
                    ?.filter { it in 'a'..'z' || it in '0'..'9' }
                    ?.take(32)?.takeIf { it.isNotEmpty() }
            }
        }
    }.getOrNull()

    // content://kr.co.viewplus.market.session 한 줄을 읽어 Map으로. 저장하지 않는다.
    private fun readSession(): Map<String, Any?>? {
        return try {
            val cur = contentResolver.query(sessionUri, null, null, null, null)
                ?: return null // 마켓앱 없음
            cur.use { c ->
                if (!c.moveToFirst()) {
                    // 마켓은 있으나 행이 없음 = 로그아웃 취급(빈 토큰).
                    return mapOf(
                        "sessionToken" to "", "deviceId" to "", "userId" to "",
                        "registered" to false, "downloadPolicy" to "login",
                    )
                }
                mapOf(
                    "sessionToken" to col(c, "sessionToken"),
                    "deviceId" to col(c, "deviceId"),
                    "userId" to col(c, "userId"),
                    "registered" to "Y".equals(col(c, "registered"), ignoreCase = true),
                    "downloadPolicy" to col(c, "downloadPolicy").ifEmpty { "login" },
                )
            }
        } catch (se: SecurityException) {
            // 서명키 불일치 → 못 읽음. 마켓 없음과 동일하게 null(모바일 경로로 취급).
            null
        } catch (e: Exception) {
            null
        }
    }

    private fun col(c: Cursor, name: String): String {
        val i = c.getColumnIndex(name)
        return if (i < 0) "" else (c.getString(i) ?: "")
    }

    private fun verifySession(token: String): Int {
        if (token.isEmpty()) return 401
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL(verifyUrl).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                setRequestProperty("Authorization", "Bearer $token")
                connectTimeout = 8000
                readTimeout = 8000
            }
            conn.responseCode
        } catch (e: Exception) {
            -1 // 네트워크 오류 → 상위에서 '통과(기존 유지)'로 처리
        } finally {
            conn?.disconnect()
        }
    }

    private fun openStoreLogin(): Boolean {
        return try {
            val uri = Uri.parse("viewplus://login?return=$packageName")
            startActivity(Intent(Intent.ACTION_VIEW, uri)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun startObserve(): Boolean {
        return try {
            if (sessionObserver == null) {
                sessionObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
                    override fun onChange(selfChange: Boolean) {
                        storeChannel?.invokeMethod("onSessionChanged", null)
                    }
                }
                contentResolver.registerContentObserver(sessionUri, true, sessionObserver!!)
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun stopObserve(): Boolean {
        try {
            sessionObserver?.let { contentResolver.unregisterContentObserver(it) }
        } catch (e: Exception) {
        }
        sessionObserver = null
        return true
    }

    override fun onDestroy() {
        stopObserve()
        super.onDestroy()
    }
}
