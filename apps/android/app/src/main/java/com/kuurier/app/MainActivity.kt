package com.kuurier.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import com.kuurier.app.ui.navigation.KuurierNavHost
import com.kuurier.app.ui.theme.KuurierTheme
import dagger.hilt.android.AndroidEntryPoint

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            KuurierTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    KuurierNavHost()
                }
            }
        }
    }
}
