package kr.co.mychannel.meeting.prism

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "app/fullscreen"

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
                    else -> result.notImplemented()
                }
            }
    }
}
