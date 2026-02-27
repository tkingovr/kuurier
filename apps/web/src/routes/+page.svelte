<script lang="ts">
	import { register } from '$lib/stores/auth';
	import { goto } from '$app/navigation';

	let inviteCode = $state('');
	let error = $state('');
	let registering = $state(false);

	async function handleRegister() {
		if (!inviteCode.trim()) return;
		error = '';
		registering = true;
		try {
			await register(inviteCode.trim());
			goto('/feed');
		} catch (e) {
			error = `Registration failed: ${e}`;
		} finally {
			registering = false;
		}
	}
</script>

<div class="auth-screen">
	<div class="auth-container">
		<div class="auth-logo">K</div>
		<h1>Kuurier</h1>
		<p class="subtitle">Privacy-first activist platform</p>

		<div class="auth-form">
			<p>Enter your invite code to register.</p>
			<input type="text" bind:value={inviteCode} placeholder="KUU-XXXXXX" maxlength="10" />
			<button class="btn-primary" onclick={handleRegister} disabled={registering || !inviteCode.trim()}>
				{registering ? 'Registering...' : 'Register'}
			</button>
			{#if error}<p class="error">{error}</p>{/if}
		</div>

		<div class="auth-warning">
			<p>For maximum privacy, use <a href="https://www.torproject.org/download/" target="_blank">Tor Browser</a>.</p>
			<p class="note">The web app cannot route traffic through Tor. The desktop app does this automatically.</p>
		</div>

		<div class="auth-footer">
			<p>No invite? Get one from a trusted member.</p>
			<p class="note">Your Ed25519 keypair is generated in your browser. No personal data is collected.</p>
		</div>
	</div>
</div>

<style>
	.auth-screen { display: flex; align-items: center; justify-content: center; height: 100vh; padding: 20px; }
	.auth-container { text-align: center; max-width: 420px; width: 100%; }
	.auth-logo { width: 72px; height: 72px; border-radius: 18px; background: var(--color-accent); color: var(--color-bg); display: flex; align-items: center; justify-content: center; font-size: 36px; font-weight: 700; margin: 0 auto 16px; }
	h1 { font-size: 28px; font-weight: 700; margin-bottom: 8px; }
	.subtitle { color: var(--color-text-secondary); margin-bottom: 32px; }
	.auth-form { margin-bottom: 24px; }
	.auth-form p { margin-bottom: 12px; font-size: 14px; }
	.auth-form input { width: 100%; border: 1px solid var(--color-border); border-radius: 8px; padding: 12px; font-size: 18px; text-align: center; font-family: var(--font-mono); letter-spacing: 2px; margin-bottom: 12px; text-transform: uppercase; }
	.btn-primary { background: var(--color-accent); color: var(--color-bg); border: none; padding: 12px 32px; border-radius: 8px; font-size: 16px; font-weight: 600; width: 100%; cursor: pointer; }
	.btn-primary:disabled { opacity: 0.5; }
	.error { color: var(--color-danger); margin-top: 12px; font-size: 14px; }
	.auth-warning { background: rgba(245, 158, 11, 0.1); border: 1px solid rgba(245, 158, 11, 0.3); border-radius: 8px; padding: 16px; margin-bottom: 24px; }
	.auth-warning p { font-size: 14px; margin-bottom: 4px; }
	.auth-warning a { color: var(--color-accent); }
	.auth-footer { font-size: 13px; color: var(--color-text-secondary); }
	.note { font-size: 12px; opacity: 0.7; margin-top: 4px; }
</style>
