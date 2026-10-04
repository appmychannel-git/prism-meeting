package kr.co.mychannel.meeting.prism

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.database.ContentObserver
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.HttpURLConnection
import java.net.URL

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
                // 마켓 로그인 화면을 연다(끝나면 return 패키지로 자동 복귀).
                "openStoreLogin" -> result.success(openStoreLogin())
                // 마켓 로그아웃 감지(마켓이 notifyChange를 쏜다) → onSessionChanged 콜백.
                "startObserve" -> result.success(startObserve())
                "stopObserve" -> result.success(stopObserve())
                else -> result.notImplemented()
            }
        }
    }

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
