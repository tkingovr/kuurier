<script lang="ts">
	import { onMount, onDestroy } from 'svelte';
	import { startLinking, checkLinkStatus } from '$lib/stores/auth';
	import { goto } from '$app/navigation';
	import type { QrCodeData } from '$lib/api';

	let qrData = $state<QrCodeData | null>(null);
	let linkError = $state('');
	let polling = $state(false);
	let pollInterval: ReturnType<typeof setInterval> | null = null;

	async function beginLink() {
		linkError = '';
		try {
			qrData = await startLinking();
			polling = true;

			// Poll every 2 seconds for link completion
			pollInterval = setInterval(async () => {
				if (!qrData) return;
				try {
					const linked = await checkLinkStatus(qrData.device_id);
					if (linked) {
						stopPolling();
						goto('/feed');
					}
				} catch (e) {
					console.error('Poll error:', e);
				}
			}, 2000);

			// Stop polling after 5 minutes
			setTimeout(() => {
				if (polling) {
					stopPolling();
					linkError = 'QR code expired. Please try again.';
					qrData = null;
				}
			}, 300000);
		} catch (e) {
			linkError = `Failed to generate QR code: ${e}`;
		}
	}

	function stopPolling() {
		polling = false;
		if (pollInterval) {
			clearInterval(pollInterval);
			pollInterval = null;
		}
	}

	onDestroy(() => {
		stopPolling();
	});
</script>

<div class="auth-screen">
	<div class="auth-container">
		<div class="auth-logo">K</div>
		<h1 class="auth-title">Kuurier</h1>
		<p class="auth-subtitle">Privacy-first activist platform</p>

		{#if !qrData}
			<div class="auth-info">
				<p>Link your mobile device to get started.</p>
				<p class="auth-detail">
					Open Kuurier on your phone, go to Settings, and scan the QR code displayed here.
				</p>
			</div>

			<button class="btn-primary" onclick={beginLink}>
				Link Mobile Device
			</button>

			{#if linkError}
				<p class="error">{linkError}</p>
			{/if}
		{:else}
			<div class="qr-container">
				<div class="qr-code">
					<pre>{qrData.qr_image}</pre>
				</div>
				<p class="qr-instruction">
					Scan this QR code with your Kuurier mobile app
				</p>
				{#if polling}
					<div class="polling-indicator">
						<span class="spinner"></span>
						Waiting for mobile device...
					</div>
				{/if}
			</div>

			<button class="btn-secondary" onclick={() => { stopPolling(); qrData = null; }}>
				Cancel
			</button>
		{/if}

		<div class="auth-footer">
			<p>No account? Get an invite from a trusted member.</p>
			<p class="auth-note">Your Ed25519 keypair is your identity. No email or phone required.</p>
		</div>
	</div>
</div>

<style>
	.auth-screen {
		display: flex;
		align-items: center;
		justify-content: center;
		height: 100vh;
		padding: 20px;
	}

	.auth-container {
		text-align: center;
		max-width: 420px;
		width: 100%;
	}

	.auth-logo {
		width: 72px;
		height: 72px;
		border-radius: 18px;
		background: var(--color-accent);
		color: var(--color-bg);
		display: flex;
		align-items: center;
		justify-content: center;
		font-size: 36px;
		font-weight: 700;
		margin: 0 auto 16px;
	}

	.auth-title {
		font-size: 28px;
		font-weight: 700;
		margin-bottom: 8px;
	}

	.auth-subtitle {
		color: var(--color-text-secondary);
		margin-bottom: 32px;
	}

	.auth-info {
		margin-bottom: 24px;
	}

	.auth-info p {
		margin-bottom: 8px;
	}

	.auth-detail {
		color: var(--color-text-secondary);
		font-size: 14px;
	}

	.btn-primary {
		background: var(--color-accent);
		color: var(--color-bg);
		border: none;
		padding: 12px 32px;
		border-radius: var(--radius-md);
		font-size: 16px;
		font-weight: 600;
		width: 100%;
		transition: opacity 0.15s;
	}

	.btn-primary:hover {
		opacity: 0.9;
	}

	.btn-secondary {
		background: transparent;
		color: var(--color-text-secondary);
		border: 1px solid var(--color-border);
		padding: 10px 24px;
		border-radius: var(--radius-md);
		font-size: 14px;
		margin-top: 16px;
		width: 100%;
	}

	.btn-secondary:hover {
		background: var(--color-surface-hover);
	}

	.qr-container {
		margin: 24px 0;
	}

	.qr-code {
		background: white;
		padding: 16px;
		border-radius: var(--radius-lg);
		display: inline-block;
		margin-bottom: 16px;
	}

	.qr-code pre {
		font-size: 4px;
		line-height: 4px;
		color: black;
		margin: 0;
		font-family: monospace;
	}

	.qr-instruction {
		color: var(--color-text-secondary);
		font-size: 14px;
	}

	.polling-indicator {
		display: flex;
		align-items: center;
		justify-content: center;
		gap: 8px;
		margin-top: 16px;
		color: var(--color-accent);
		font-size: 14px;
	}

	.spinner {
		width: 16px;
		height: 16px;
		border: 2px solid var(--color-border);
		border-top-color: var(--color-accent);
		border-radius: 50%;
		animation: spin 0.8s linear infinite;
	}

	@keyframes spin {
		to { transform: rotate(360deg); }
	}

	.error {
		color: var(--color-danger);
		margin-top: 12px;
		font-size: 14px;
	}

	.auth-footer {
		margin-top: 40px;
		font-size: 13px;
		color: var(--color-text-secondary);
	}

	.auth-note {
		margin-top: 4px;
		font-size: 12px;
		opacity: 0.7;
	}
</style>
