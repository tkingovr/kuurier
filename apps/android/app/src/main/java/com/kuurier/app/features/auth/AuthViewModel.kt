package com.kuurier.app.features.auth

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.kuurier.app.core.crypto.KeyManager
import com.kuurier.app.core.models.RegisterRequest
import com.kuurier.app.core.models.VerifyRequest
import com.kuurier.app.core.network.KuurierApi
import com.kuurier.app.core.storage.SecureStorage
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

data class AuthUiState(
    val isLoading: Boolean = false,
    val isAuthenticated: Boolean = false,
    val displayName: String = "",
    val error: String? = null
)

@HiltViewModel
class AuthViewModel @Inject constructor(
    private val api: KuurierApi,
    private val keyManager: KeyManager,
    private val secureStorage: SecureStorage
) : ViewModel() {

    private val _uiState = MutableStateFlow(AuthUiState())
    val uiState: StateFlow<AuthUiState> = _uiState.asStateFlow()

    init {
        if (secureStorage.isAuthenticated) {
            _uiState.value = _uiState.value.copy(isAuthenticated = true)
        }
    }

    fun updateDisplayName(name: String) {
        _uiState.value = _uiState.value.copy(displayName = name, error = null)
    }

    fun register() {
        val displayName = _uiState.value.displayName.trim()
        if (displayName.isEmpty()) {
            _uiState.value = _uiState.value.copy(error = "Display name is required")
            return
        }

        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isLoading = true, error = null)
            try {
                val (publicKey, _) = keyManager.generateKeyPair()

                val challenge = api.register(
                    RegisterRequest(publicKey = publicKey, displayName = displayName)
                )

                val signature = keyManager.sign(challenge.challenge)
                    ?: throw Exception("Failed to sign challenge")

                val auth = api.verify(
                    VerifyRequest(userId = challenge.userId, signature = signature)
                )

                secureStorage.authToken = auth.token
                secureStorage.userId = auth.userId
                secureStorage.displayName = displayName

                _uiState.value = _uiState.value.copy(
                    isLoading = false,
                    isAuthenticated = true
                )
            } catch (e: Exception) {
                _uiState.value = _uiState.value.copy(
                    isLoading = false,
                    error = e.message ?: "Registration failed"
                )
            }
        }
    }
}
