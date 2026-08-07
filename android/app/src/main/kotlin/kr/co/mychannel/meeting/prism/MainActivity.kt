package kr.co.mychannel.meeting.prism

import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
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
}
