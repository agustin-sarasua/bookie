package com.bookie.bookie_studio

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.PatternMatcher
import android.util.Log
import androidx.annotation.NonNull
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Joining the toy's own WiFi network, so the app can write the card in place.
 *
 * The toy raises a WPA2 access point called Bookie-XXXX with a passphrase both
 * sides know, which is what lets this be one tap rather than a trip to system
 * settings: WifiNetworkSpecifier asks Android to connect to a network matching
 * a pattern, and the user gets a system dialog naming it.
 *
 * The important half is bindProcessToNetwork. The toy's network has no
 * internet, so Android leaves the phone's data connection as the default route
 * and every HTTP request would go out over cellular and never reach
 * 192.168.4.1. Binding pins this process to the toy until we let go.
 */
class ToyLinkPlugin(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.bookie.studio/toy"
        private const val TAG = "ToyLinkPlugin"
    }

    private val connectivity: ConnectivityManager
        get() = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private var callback: ConnectivityManager.NetworkCallback? = null

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: MethodChannel.Result) {
        when (call.method) {
            "join" -> join(
                call.argument<String>("prefix") ?: "Bookie-",
                call.argument<String>("passphrase") ?: "",
                (call.argument<Number>("timeoutMs") ?: 30000).toInt(),
                result
            )
            "leave" -> {
                leave()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun join(
        prefix: String,
        passphrase: String,
        timeoutMs: Int,
        result: MethodChannel.Result
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            // Android 8 and 9 can only be pointed at a network by hand.
            return result.error("unsupported", "This Android is too old to join by itself.", null)
        }
        leave()

        val specifier = WifiNetworkSpecifier.Builder()
            .setSsidPattern(PatternMatcher(prefix, PatternMatcher.PATTERN_PREFIX))
            .setWpa2Passphrase(passphrase)
            .build()

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            // Without this the request waits forever for a network that can
            // reach the internet, which the toy is never going to be.
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()

        // The callback fires again on every change of the network's state; the
        // Flutter result may only be answered once.
        var answered = false
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                val bound = connectivity.bindProcessToNetwork(network)
                Log.i(TAG, "joined the toy, bound=$bound")
                if (!answered) {
                    answered = true
                    result.success(bound)
                }
            }

            override fun onUnavailable() {
                Log.w(TAG, "no toy network found, or the user said no")
                if (!answered) {
                    answered = true
                    result.success(null)
                }
            }

            override fun onLost(network: Network) {
                Log.i(TAG, "the toy network went away")
                connectivity.bindProcessToNetwork(null)
            }
        }
        callback = cb

        try {
            connectivity.requestNetwork(request, cb, timeoutMs)
        } catch (e: SecurityException) {
            callback = null
            result.error("failed", e.message ?: "not allowed to join a network", null)
        }
    }

    /** Let the phone go back to its own network. Safe to call when not joined. */
    fun leave() {
        connectivity.bindProcessToNetwork(null)
        callback?.let {
            try {
                connectivity.unregisterNetworkCallback(it)
            } catch (e: IllegalArgumentException) {
                // Already gone; nothing to undo.
            }
        }
        callback = null
    }
}
