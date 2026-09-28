package com.bookie.bookie_studio

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var cardPlugin: CardPlugin? = null
    private var toyPlugin: ToyLinkPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val plugin = CardPlugin(applicationContext)
        plugin.activity = this
        cardPlugin = plugin

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CardPlugin.CHANNEL)
            .setMethodCallHandler(plugin)

        val toy = ToyLinkPlugin(applicationContext)
        toyPlugin = toy
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ToyLinkPlugin.CHANNEL)
            .setMethodCallHandler(toy)
    }

    // The folder picker comes back here rather than through a plugin binding,
    // because CardPlugin is part of this app rather than a published package.
    @Deprecated("Forwarded from the platform for the SAF folder picker")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (cardPlugin?.onActivityResult(requestCode, resultCode, data) == true) return
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        cardPlugin?.activity = null
        cardPlugin = null
        // Leaving the process bound to the toy would strand the next app that
        // shares this process, and the phone's data connection with it.
        toyPlugin?.leave()
        toyPlugin = null
        super.onDestroy()
    }
}
