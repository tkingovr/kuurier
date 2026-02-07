package com.kuurier.app.ui.screens.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.kuurier.app.features.settings.SettingsViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(viewModel: SettingsViewModel = hiltViewModel()) {
    val uiState by viewModel.uiState.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(title = { Text("Settings") })
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
        ) {
            item {
                // Profile section
                Card(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(16.dp)
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Text(
                            text = uiState.displayName.ifEmpty { "Anonymous" },
                            style = MaterialTheme.typography.titleLarge
                        )
                        Spacer(modifier = Modifier.height(4.dp))
                        Text(
                            text = "Trust Score: ${uiState.trustScore}",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }

            item {
                SettingsSection(title = "Notifications") {
                    SettingsRow(
                        icon = Icons.Default.NotificationsOff,
                        title = "Quiet Hours",
                        subtitle = "Configure notification schedule",
                        onClick = { /* TODO: Navigate to quiet hours */ }
                    )
                    SettingsRow(
                        icon = Icons.Default.Subscriptions,
                        title = "Subscriptions",
                        subtitle = "Manage topic and location subscriptions",
                        onClick = { /* TODO: Navigate to subscriptions */ }
                    )
                }
            }

            item {
                SettingsSection(title = "Security") {
                    SettingsRow(
                        icon = Icons.Default.Lock,
                        title = "App Lock",
                        subtitle = "Set a PIN to lock the app",
                        onClick = { /* TODO: Navigate to app lock */ }
                    )
                    SettingsRow(
                        icon = Icons.Default.Shield,
                        title = "Duress Mode",
                        subtitle = "Set a secondary PIN for emergencies",
                        onClick = { /* TODO: Navigate to duress mode */ }
                    )
                    SettingsRow(
                        icon = Icons.Default.DeleteForever,
                        title = "Panic Wipe",
                        subtitle = "Instantly erase all local data",
                        onClick = viewModel::panicWipe,
                        isDestructive = true
                    )
                }
            }

            item {
                SettingsSection(title = "Account") {
                    SettingsRow(
                        icon = Icons.AutoMirrored.Filled.Logout,
                        title = "Sign Out",
                        subtitle = "Remove account from this device",
                        onClick = viewModel::signOut,
                        isDestructive = true
                    )
                }
            }

            item {
                Spacer(modifier = Modifier.height(16.dp))
                Text(
                    text = "Kuurier v0.1.0",
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(16.dp),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

@Composable
private fun SettingsSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
        Text(
            text = title,
            style = MaterialTheme.typography.titleSmall,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.padding(bottom = 4.dp)
        )
        Card(modifier = Modifier.fillMaxWidth()) {
            Column(content = content)
        }
    }
}

@Composable
private fun SettingsRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    onClick: () -> Unit,
    isDestructive: Boolean = false
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = if (isDestructive) MaterialTheme.colorScheme.error
            else MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(24.dp)
        )
        Spacer(modifier = Modifier.width(16.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyLarge,
                color = if (isDestructive) MaterialTheme.colorScheme.error
                else MaterialTheme.colorScheme.onSurface
            )
            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}
