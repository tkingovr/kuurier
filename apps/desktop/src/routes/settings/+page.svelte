<script lang="ts">
	import { onMount } from 'svelte';
	import { authState, logout, panicWipe } from '$lib/stores/auth';
	import { torStatus, toggleTor, reconnectTor, connectionLabel } from '$lib/stores/connection';
	import { getConfig, setApiUrl, setDisplayName, getMe, type AppConfig } from '$lib/api';

	let config = $state<AppConfig | null>(null);
	let apiUrlInput = $state('');
	let displayNameInput = $state('');
	let displayNameSaved = $state(false);
	let showPanicConfirm = $state(false);

	onMount(async () => {
		try {
			config = await getConfig();
			apiUrlInput = config.api_base_url;
		} catch (e) {
			console.error('Failed to load config:', e);
		}
		try {
			const profile = await getMe();
			if (profile.display_name) {
				displayNameInput = profile.display_name;
			}
		} catch (e) {
			console.error('Failed to load profile:', e);
		}
	});

	async function handleSaveApiUrl() {
		if (!apiUrlInput.trim()) return;
		try {
			await setApiUrl(apiUrlInput);
		} catch (e) {
			console.error('Failed to save API URL:', e);
		}
	}

	async function handleSaveDisplayName() {
		if (!displayNameInput.trim()) return;
		try {
			await setDisplayName(displayNameInput.trim());
			displayNameSaved = true;
			setTimeout(() => (displayNameSaved = false), 2000);
		} catch (e) {
			console.error('Failed to save display name:', e);
		}
	}

	async function handleTorToggle() {
		const newEnabled = $torStatus.status === 'Disabled';
		await toggleTor(newEnabled);
	}

	async function handlePanicWipe() {
		await panicWipe();
		window.location.reload();
	}
</script>

<div class="settings-page">
	<div class="settings-header">
		<h2>Settings</h2>
	</div>

	<div class="settings-content">
		<section class="settings-section">
			<h3>Identity</h3>
			<div class="setting-row vertical">
				<span class="setting-label">Display Name</span>
				<p class="setting-desc">Visible to others in channels and DMs.</p>
				<div class="input-row">
					<input type="text" bind:value={displayNameInput} placeholder="Enter a display name" maxlength="30" />
					<button class="btn-save" onclick={handleSaveDisplayName}>
						{displayNameSaved ? 'Saved' : 'Save'}
					</button>
				</div>
			</div>
			<div class="setting-row">
				<span class="setting-label">User ID</span>
				<code class="setting-value">{$authState.user_id ?? 'N/A'}</code>
			</div>
			<div class="setting-row">
				<span class="setting-label">Trust Score</span>
				<span class="setting-value trust-score">{$authState.trust_score ?? 0}</span>
			</div>
			<div class="setting-row">
				<span class="setting-label">Device ID</span>
				<code class="setting-value">{$authState.device_id ?? 'N/A'}</code>
			</div>
		</section>

		<section class="settings-section">
			<h3>Network</h3>
			<div class="setting-row">
				<div>
					<span class="setting-label">Tor Routing</span>
					<p class="setting-desc">{$connectionLabel}</p>
				</div>
				<button class="toggle-btn" class:active={$torStatus.status !== 'Disabled'} onclick={handleTorToggle}>
					{$torStatus.status === 'Disabled' ? 'Enable' : 'Disable'}
				</button>
			</div>
			{#if $torStatus.status === 'Error'}
				<button class="btn-retry" onclick={reconnectTor}>Retry Tor Connection</button>
			{/if}
		</section>

		<section class="settings-section">
			<h3>Server</h3>
			<div class="setting-row vertical">
				<span class="setting-label">API URL</span>
				<div class="input-row">
					<input type="url" bind:value={apiUrlInput} placeholder="http://localhost:8080/api/v1" />
					<button class="btn-save" onclick={handleSaveApiUrl}>Save</button>
				</div>
			</div>
		</section>

		<section class="settings-section">
			<h3>Account</h3>
			<button class="btn-logout" onclick={logout}>Log Out</button>
		</section>

		<section class="settings-section danger-zone">
			<h3>Danger Zone</h3>
			<p class="setting-desc">Emergency wipe destroys all local data, keys, and cached messages. This cannot be undone.</p>
			{#if !showPanicConfirm}
				<button class="btn-panic" onclick={() => (showPanicConfirm = true)}>
					Emergency Wipe
				</button>
			{:else}
				<div class="panic-confirm">
					<p>Are you absolutely sure? This will:</p>
					<ul>
						<li>Delete your Ed25519 private key from the keychain</li>
						<li>Wipe the local message database</li>
						<li>Clear all Tor data</li>
						<li>Log you out permanently on this device</li>
					</ul>
					<div class="panic-buttons">
						<button class="btn-cancel" onclick={() => (showPanicConfirm = false)}>Cancel</button>
						<button class="btn-panic-confirm" onclick={handlePanicWipe}>Wipe Everything</button>
					</div>
				</div>
			{/if}
		</section>
	</div>
</div>

<style>
	.settings-page { height: 100%; display: flex; flex-direction: column; }

	.settings-header {
		padding: 16px 20px; border-bottom: 1px solid var(--color-border);
	}

	.settings-header h2 { font-size: 20px; font-weight: 600; }

	.settings-content {
		flex: 1; overflow-y: auto; padding: 16px 20px;
	}

	.settings-section {
		padding: 20px 0; border-bottom: 1px solid var(--color-border);
	}

	.settings-section h3 { font-size: 16px; font-weight: 600; margin-bottom: 12px; }

	.setting-row {
		display: flex; align-items: center; justify-content: space-between;
		padding: 8px 0;
	}

	.setting-row.vertical { flex-direction: column; align-items: flex-start; gap: 8px; }

	.setting-label { font-size: 14px; color: var(--color-text-secondary); }
	.setting-desc { font-size: 13px; color: var(--color-text-secondary); margin-top: 2px; }

	.setting-value { font-size: 14px; font-family: var(--font-mono); }
	.trust-score { color: var(--color-accent); font-weight: 600; }

	code { background: var(--color-surface-hover); padding: 2px 6px; border-radius: var(--radius-sm); }

	.toggle-btn {
		padding: 6px 16px; border-radius: var(--radius-md);
		border: 1px solid var(--color-border); background: none;
		color: var(--color-text-secondary); font-size: 13px;
	}

	.toggle-btn.active {
		border-color: var(--color-accent); color: var(--color-accent);
		background: color-mix(in srgb, var(--color-accent) 10%, transparent);
	}

	.input-row { display: flex; gap: 8px; width: 100%; }

	.input-row input {
		flex: 1; border: 1px solid var(--color-border); border-radius: var(--radius-md);
		padding: 8px 12px; font-size: 14px; font-family: var(--font-mono);
	}

	.btn-save, .btn-retry {
		background: var(--color-accent); color: var(--color-bg);
		border: none; padding: 8px 16px; border-radius: var(--radius-md);
		font-size: 13px; font-weight: 600;
	}

	.btn-retry { margin-top: 8px; }

	.btn-logout {
		background: none; border: 1px solid var(--color-border);
		color: var(--color-text); padding: 8px 20px; border-radius: var(--radius-md);
		font-size: 14px;
	}

	.btn-logout:hover { background: var(--color-surface-hover); }

	.danger-zone h3 { color: var(--color-danger); }

	.btn-panic {
		background: var(--color-danger); color: white;
		border: none; padding: 10px 24px; border-radius: var(--radius-md);
		font-size: 14px; font-weight: 600; margin-top: 12px;
	}

	.panic-confirm {
		background: color-mix(in srgb, var(--color-danger) 10%, transparent);
		border: 1px solid var(--color-danger);
		border-radius: var(--radius-md); padding: 16px; margin-top: 12px;
	}

	.panic-confirm p { font-size: 14px; font-weight: 600; margin-bottom: 8px; }
	.panic-confirm ul { font-size: 13px; padding-left: 20px; margin-bottom: 16px; color: var(--color-text-secondary); }
	.panic-confirm li { margin-bottom: 4px; }

	.panic-buttons { display: flex; gap: 8px; }
	.btn-cancel { background: none; border: 1px solid var(--color-border); padding: 8px 16px; border-radius: var(--radius-md); color: var(--color-text); font-size: 13px; }
	.btn-panic-confirm { background: var(--color-danger); color: white; border: none; padding: 8px 24px; border-radius: var(--radius-md); font-size: 13px; font-weight: 600; }
</style>
