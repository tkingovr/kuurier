package com.kuurier.app.features.push

import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.kuurier.app.core.config.AppConfig
import com.kuurier.app.core.models.PushTokenRequest
import com.kuurier.app.core.network.KuurierApi
import com.kuurier.app.core.storage.SecureStorage
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import javax.inject.Inject

@AndroidEntryPoint
class KuurierFirebaseMessagingService : FirebaseMessagingService() {

    @Inject lateinit var api: KuurierApi
    @Inject lateinit var secureStorage: SecureStorage

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    override fun onNewToken(token: String) {
        super.onNewToken(token)
        if (secureStorage.isAuthenticated) {
            scope.launch {
                try {
                    api.registerPushToken(
                        PushTokenRequest(token = token, platform = AppConfig.PLATFORM)
                    )
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to register push token", e)
                }
            }
        }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        super.onMessageReceived(message)
        // TODO: Handle incoming push notifications
        // - Parse notification type (alert, message, event, etc.)
        // - Show system notification
        // - Check quiet hours before displaying
        Log.d(TAG, "Push received: ${message.data}")
    }

    companion object {
        private const val TAG = "KuurierFCM"
    }
}
