package com.kuurier.app.core.network

import com.kuurier.app.core.storage.SecureStorage
import okhttp3.Interceptor
import okhttp3.Response
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AuthInterceptor @Inject constructor(
    private val secureStorage: SecureStorage
) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request().newBuilder().apply {
            addHeader("Content-Type", "application/json")
            addHeader("Accept", "application/json")
            secureStorage.authToken?.let { token ->
                addHeader("Authorization", "Bearer $token")
            }
        }.build()

        val response = chain.proceed(request)

        // Clear auth token on 401
        if (response.code == 401) {
            secureStorage.authToken = null
        }

        return response
    }
}
