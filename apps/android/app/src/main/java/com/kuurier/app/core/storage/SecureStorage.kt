package com.kuurier.app.core.storage

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class SecureStorage @Inject constructor(
    @ApplicationContext context: Context
) {
    private val masterKey = MasterKey.Builder(context)
        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
        .build()

    private val prefs: SharedPreferences = EncryptedSharedPreferences.create(
        context,
        "kuurier_secure_prefs",
        masterKey,
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
    )

    var authToken: String?
        get() = prefs.getString(KEY_AUTH_TOKEN, null)
        set(value) = prefs.edit().putString(KEY_AUTH_TOKEN, value).apply()

    var publicKey: String?
        get() = prefs.getString(KEY_PUBLIC_KEY, null)
        set(value) = prefs.edit().putString(KEY_PUBLIC_KEY, value).apply()

    var privateKey: String?
        get() = prefs.getString(KEY_PRIVATE_KEY, null)
        set(value) = prefs.edit().putString(KEY_PRIVATE_KEY, value).apply()

    var userId: String?
        get() = prefs.getString(KEY_USER_ID, null)
        set(value) = prefs.edit().putString(KEY_USER_ID, value).apply()

    var displayName: String?
        get() = prefs.getString(KEY_DISPLAY_NAME, null)
        set(value) = prefs.edit().putString(KEY_DISPLAY_NAME, value).apply()

    var appLockPin: String?
        get() = prefs.getString(KEY_APP_LOCK_PIN, null)
        set(value) = prefs.edit().putString(KEY_APP_LOCK_PIN, value).apply()

    var duressPin: String?
        get() = prefs.getString(KEY_DURESS_PIN, null)
        set(value) = prefs.edit().putString(KEY_DURESS_PIN, value).apply()

    val isAuthenticated: Boolean
        get() = authToken != null && privateKey != null

    fun wipeAll() {
        prefs.edit().clear().apply()
    }

    companion object {
        private const val KEY_AUTH_TOKEN = "auth_token"
        private const val KEY_PUBLIC_KEY = "public_key"
        private const val KEY_PRIVATE_KEY = "private_key"
        private const val KEY_USER_ID = "user_id"
        private const val KEY_DISPLAY_NAME = "display_name"
        private const val KEY_APP_LOCK_PIN = "app_lock_pin"
        private const val KEY_DURESS_PIN = "duress_pin"
    }
}
