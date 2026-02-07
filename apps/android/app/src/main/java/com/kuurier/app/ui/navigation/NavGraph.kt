package com.kuurier.app.ui.navigation

import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Campaign
import androidx.compose.material.icons.filled.Event
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.Newspaper
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.kuurier.app.core.storage.SecureStorage
import com.kuurier.app.ui.screens.alerts.AlertsScreen
import com.kuurier.app.ui.screens.auth.AuthScreen
import com.kuurier.app.ui.screens.events.EventsScreen
import com.kuurier.app.ui.screens.feed.FeedScreen
import com.kuurier.app.ui.screens.map.MapScreen
import com.kuurier.app.ui.screens.settings.SettingsScreen
import javax.inject.Inject

sealed class Screen(val route: String, val label: String, val icon: ImageVector) {
    data object Feed : Screen("feed", "Feed", Icons.Default.Newspaper)
    data object Map : Screen("map", "Map", Icons.Default.Map)
    data object Events : Screen("events", "Events", Icons.Default.Event)
    data object Alerts : Screen("alerts", "Alerts", Icons.Default.Campaign)
    data object Settings : Screen("settings", "Settings", Icons.Default.Settings)
}

val bottomNavScreens = listOf(
    Screen.Feed,
    Screen.Map,
    Screen.Events,
    Screen.Alerts,
    Screen.Settings
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun KuurierNavHost() {
    val navController = rememberNavController()
    val navBackStackEntry by navController.currentBackStackEntryAsState()
    val currentDestination = navBackStackEntry?.destination

    val showBottomBar = bottomNavScreens.any { screen ->
        currentDestination?.hierarchy?.any { it.route == screen.route } == true
    }

    Scaffold(
        bottomBar = {
            if (showBottomBar) {
                NavigationBar {
                    bottomNavScreens.forEach { screen ->
                        NavigationBarItem(
                            icon = { Icon(screen.icon, contentDescription = screen.label) },
                            label = { Text(screen.label) },
                            selected = currentDestination?.hierarchy?.any { it.route == screen.route } == true,
                            onClick = {
                                navController.navigate(screen.route) {
                                    popUpTo(navController.graph.findStartDestination().id) {
                                        saveState = true
                                    }
                                    launchSingleTop = true
                                    restoreState = true
                                }
                            }
                        )
                    }
                }
            }
        }
    ) { innerPadding ->
        NavHost(
            navController = navController,
            startDestination = "auth",
            modifier = Modifier.padding(innerPadding)
        ) {
            composable("auth") {
                AuthScreen(
                    onAuthenticated = {
                        navController.navigate(Screen.Feed.route) {
                            popUpTo("auth") { inclusive = true }
                        }
                    }
                )
            }
            composable(Screen.Feed.route) { FeedScreen() }
            composable(Screen.Map.route) { MapScreen() }
            composable(Screen.Events.route) { EventsScreen() }
            composable(Screen.Alerts.route) { AlertsScreen() }
            composable(Screen.Settings.route) { SettingsScreen() }
        }
    }
}
