<script lang="ts">
	import { onMount } from 'svelte';
	import { authState, logout } from '$lib/stores/auth';
	import { setDisplayName, getMe } from '$lib/api';
	import { goto } from '$app/navigation';

	let displayNameInput = $state('');
	let displayNameSaved = $state(false);

	onMount(async () => {
		try {
			const profile = await getMe();
			if (profile.display_name) {
				displayNameInput = profile.display_name;
			}
		} catch (e) {
			console.error('Failed to load profile:', e);
		}
	});

	function handleLogout() {
		logout();
		goto('/');
	}

	function handleWipe() {
		sessionStorage.clear();
		localStorage.clear();
		logout();
		goto('/');
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
</script>

<div class="settings-page">
	<div class="settings-header"><h2>Settings</h2></div>
	<div class="settings-content">
		<section>
			<h3>Identity</h3>
			<div class="row vertical">
				<span class="label">Display Name</span>
				<p class="dim">Visible to others in channels and DMs.</p>
				<div class="input-row">
					<input type="text" bind:value={displayNameInput} placeholder="Enter a display name" maxlength="30" />
					<button class="btn-primary" onclick={handleSaveDisplayName}>
						{displayNameSaved ? 'Saved' : 'Save'}
					</button>
				</div>
			</div>
			<div class="row">
				<span class="label">User ID</span>
				<code>{$authState.user_id ?? 'N/A'}</code>
			</div>
			<div class="row">
				<span class="label">Trust Score</span>
				<span class="accent">{$authState.trust_score ?? 0}</span>
			</div>
		</section>

		<section>
			<h3>Privacy Notice</h3>
			<p class="dim">
				The web app cannot route traffic through Tor. For maximum privacy,
				use the <strong>desktop app</strong> (macOS, Linux, Windows) which routes all
				traffic through Tor automatically, or use <strong>Tor Browser</strong>.
			</p>
			<p class="dim">
				Your private key is stored in sessionStorage and will be lost when you close this tab.
				The desktop app stores keys in the OS keychain for persistent, secure storage.
			</p>
		</section>

		<section>
			<h3>Account</h3>
			<button class="btn-secondary" onclick={handleLogout}>Log Out</button>
		</section>

		<section class="danger">
			<h3>Danger Zone</h3>
			<p class="dim">Clear all browser storage including your private key.</p>
			<button class="btn-danger" onclick={handleWipe}>Wipe Browser Data</button>
		</section>
	</div>
</div>

<style>
	.settings-page { height: 100%; display: flex; flex-direction: column; }
	.settings-header { padding: 16px 20px; border-bottom: 1px solid var(--color-border); }
	.settings-header h2 { font-size: 20px; font-weight: 600; }
	.settings-content { flex: 1; overflow-y: auto; padding: 16px 20px; }
	section { padding: 20px 0; border-bottom: 1px solid var(--color-border); }
	h3 { font-size: 16px; font-weight: 600; margin-bottom: 12px; }
	.row { display: flex; justify-content: space-between; padding: 8px 0; font-size: 14px; }
	.row.vertical { flex-direction: column; gap: 6px; }
	.label { color: var(--color-text-secondary); }
	code { font-family: var(--font-mono); background: var(--color-surface-hover); padding: 2px 6px; border-radius: 4px; }
	.accent { color: var(--color-accent); font-weight: 600; }
	.dim { font-size: 14px; color: var(--color-text-secondary); line-height: 1.5; margin-bottom: 8px; }
	.input-row { display: flex; gap: 8px; }
	.input-row input { flex: 1; border: 1px solid var(--color-border); border-radius: 8px; padding: 8px 12px; font-size: 14px; }
	.btn-primary { background: var(--color-accent); color: var(--color-bg); border: none; padding: 8px 16px; border-radius: 8px; font-size: 13px; font-weight: 600; cursor: pointer; }
	.btn-secondary { background: none; border: 1px solid var(--color-border); color: var(--color-text); padding: 8px 20px; border-radius: 8px; font-size: 14px; cursor: pointer; }
	.btn-secondary:hover { background: var(--color-surface-hover); }
	.danger h3 { color: var(--color-danger); }
	.btn-danger { background: var(--color-danger); color: white; border: none; padding: 10px 24px; border-radius: 8px; font-size: 14px; font-weight: 600; cursor: pointer; margin-top: 8px; }
</style>
