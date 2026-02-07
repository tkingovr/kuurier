package com.kuurier.app.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

private val KuurierOrange = Color(0xFFE85D26)
private val KuurierOrangeDark = Color(0xFFFF7043)

private val DarkColorScheme = darkColorScheme(
    primary = KuurierOrangeDark,
    onPrimary = Color.White,
    primaryContainer = Color(0xFF5C1A00),
    secondary = Color(0xFFFFB59C),
    background = Color(0xFF1A1A1A),
    surface = Color(0xFF1A1A1A),
    onBackground = Color.White,
    onSurface = Color.White,
    error = Color(0xFFCF6679)
)

private val LightColorScheme = lightColorScheme(
    primary = KuurierOrange,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFFFDBCF),
    secondary = Color(0xFF77574B),
    background = Color(0xFFFFFBFF),
    surface = Color(0xFFFFFBFF),
    onBackground = Color(0xFF1A1A1A),
    onSurface = Color(0xFF1A1A1A),
    error = Color(0xFFB00020)
)

@Composable
fun KuurierTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    dynamicColor: Boolean = false,
    content: @Composable () -> Unit
) {
    val colorScheme = when {
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            val context = LocalContext.current
            if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        }
        darkTheme -> DarkColorScheme
        else -> LightColorScheme
    }

    MaterialTheme(
        colorScheme = colorScheme,
        typography = Typography(),
        content = content
    )
}
