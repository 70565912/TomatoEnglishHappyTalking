package com.example.udpipe_parser_v3

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class UdpipeParserV3Plugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private val mainHandler = Handler(Looper.getMainLooper())

    external fun parseNative(text: String, modelPath: String, presegmented: Boolean): String

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "tomato_english/udpipe_parser_v3")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "parse") {
            result.notImplemented()
            return
        }
        val text = call.argument<String>("text")
        val modelPath = call.argument<String>("modelPath")
        val presegmented = call.argument<Boolean>("presegmented") ?: false
        if (text == null || modelPath == null) {
            result.error("invalid_arguments", "text and modelPath are required", null)
            return
        }
        Thread {
            try {
                val parsed = parseNative(text, modelPath, presegmented)
                mainHandler.post { result.success(parsed) }
            } catch (error: Throwable) {
                mainHandler.post {
                    result.error("parse_failed", error.message ?: "UDPipe parse failed", null)
                }
            }
        }.start()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    companion object {
        init {
            System.loadLibrary("udpipe_parser_v3")
        }
    }
}
