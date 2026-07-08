package com.example.ensemble_sync

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val shareChannel = "ensemble_sync/share"
    private val kakaoTalkPackage = "com.kakao.talk"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, shareChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "shareToKakao" -> {
                        val text = call.argument<String>("text").orEmpty()
                        result.success(shareToKakao(text))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun shareToKakao(text: String): Boolean {
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, text)
            setPackage(kakaoTalkPackage)
        }

        if (intent.resolveActivity(packageManager) == null) {
            return false
        }

        startActivity(intent)
        return true
    }
}
