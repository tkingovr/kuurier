package com.kuurier.app.features.settings

import androidx.lifecycle.ViewModel
import com.kuurier.app.core.storage.SecureStorage
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import javax.inject.Inject

data class SettingsUiState(
    val displayName: String = "",
    val trustScore: Int = 0
)

@HiltViewModel
class SettingsViewModel @Inject constructor(
    private val secureStorage: SecureStorage
) : ViewModel() {

    private val _uiState = MutableStateFlow(
        SettingsUiState(
            displayName = secureStorage.displayName ?: "",
        )
    )
    val uiState: StateFlow<SettingsUiState> = _uiState.asStateFlow()

    fun signOut() {
        secureStorage.wipeAll()
    }

    fun panicWipe() {
        secureStorage.wipeAll()
    }
}
