<script lang="ts">
	import { onMount } from 'svelte';
	import { alerts, alertsLoading, loadAlerts, createAlert } from '$lib/stores/alerts';
	import { trustScore } from '$lib/stores/auth';

	let showCreate = $state(false);
	let newAlert = $state({ alert_type: 'general', description: '', severity: 1 });
	let creating = $state(false);

	onMount(() => {
		loadAlerts();
	});

	async function handleCreate() {
		if (!newAlert.description.trim()) return;
		creating = true;
		try {
			await createAlert(newAlert);
			showCreate = false;
			newAlert = { alert_type: 'general', description: '', severity: 1 };
		} catch {
			// Error handled in store
		} finally {
			creating = false;
		}
	}

	function severityLabel(s: number): string {
		if (s >= 3) return 'Critical';
		if (s >= 2) return 'High';
		return 'Standard';
	}

	function severityColor(s: number): string {
		if (s >= 3) return 'var(--color-danger)';
		if (s >= 2) return 'var(--color-warning)';
		return 'var(--color-accent)';
	}

	function formatTime(iso: string): string {
		const d = new Date(iso);
		const now = new Date();
		const diffMin = Math.floor((now.getTime() - d.getTime()) / 60000);
		if (diffMin < 60) return `${diffMin}m ago`;
		const diffHr = Math.floor(diffMin / 60);
		if (diffHr < 24) return `${diffHr}h ago`;
		return `${Math.floor(diffHr / 24)}d ago`;
	}
</script>

<div class="alerts-page">
	<div class="alerts-header">
		<h2>SOS Alerts</h2>
		{#if ($trustScore ?? 0) >= 100}
			<button class="btn-create" onclick={() => (showCreate = !showCreate)}>
				{showCreate ? 'Cancel' : 'Create Alert'}
			</button>
		{/if}
	</div>

	{#if showCreate}
		<div class="create-form">
			<select bind:value={newAlert.alert_type}>
				<option value="general">General</option>
				<option value="medical">Medical</option>
				<option value="security">Security</option>
				<option value="legal">Legal</option>
			</select>
			<textarea bind:value={newAlert.description} placeholder="Describe the situation..." rows="3"></textarea>
			<div class="severity-select">
				<label>Severity:</label>
				{#each [1, 2, 3] as s}
					<button
						class="severity-btn"
						class:active={newAlert.severity === s}
						style="--sev-color: {severityColor(s)}"
						onclick={() => (newAlert.severity = s)}
					>
						{severityLabel(s)}
					</button>
				{/each}
			</div>
			<button class="btn-submit" onclick={handleCreate} disabled={creating}>
				{creating ? 'Sending...' : 'Send Alert'}
			</button>
		</div>
	{/if}

	<div class="alerts-list">
		{#if $alertsLoading}
			<div class="loading">Loading alerts...</div>
		{:else if $alerts.length === 0}
			<div class="empty">No active alerts</div>
		{:else}
			{#each $alerts as alert (alert.id)}
				<div class="alert-card" style="--sev-color: {severityColor(alert.severity)}">
					<div class="alert-top">
						<span class="alert-severity" style="color: {severityColor(alert.severity)}">
							{severityLabel(alert.severity)}
						</span>
						<span class="alert-type">{alert.alert_type}</span>
						<span class="alert-status">{alert.status}</span>
						<span class="alert-time">{formatTime(alert.created_at)}</span>
					</div>
					<p class="alert-desc">{alert.description}</p>
					{#if alert.responder_count}
						<span class="alert-responders">{alert.responder_count} responding</span>
					{/if}
				</div>
			{/each}
		{/if}
	</div>
</div>

<style>
	.alerts-page { height: 100%; display: flex; flex-direction: column; }

	.alerts-header {
		display: flex; align-items: center; justify-content: space-between;
		padding: 16px 20px; border-bottom: 1px solid var(--color-border);
	}

	.alerts-header h2 { font-size: 20px; font-weight: 600; }

	.btn-create {
		background: var(--color-danger); color: white;
		border: none; padding: 8px 16px; border-radius: var(--radius-md);
		font-size: 13px; font-weight: 600;
	}

	.create-form {
		padding: 16px 20px; border-bottom: 1px solid var(--color-border);
		display: flex; flex-direction: column; gap: 8px;
	}

	.create-form select, .create-form textarea {
		border: 1px solid var(--color-border); border-radius: var(--radius-md);
		padding: 10px 12px; font-size: 14px;
	}

	.severity-select { display: flex; align-items: center; gap: 8px; }
	.severity-select label { font-size: 14px; color: var(--color-text-secondary); }

	.severity-btn {
		border: 1px solid var(--color-border); background: none;
		padding: 6px 12px; border-radius: var(--radius-sm);
		font-size: 13px; color: var(--color-text-secondary);
	}

	.severity-btn.active {
		border-color: var(--sev-color); color: var(--sev-color);
		background: color-mix(in srgb, var(--sev-color) 10%, transparent);
	}

	.btn-submit {
		background: var(--color-danger); color: white;
		border: none; padding: 10px; border-radius: var(--radius-md);
		font-size: 14px; font-weight: 600; align-self: flex-end;
	}

	.btn-submit:disabled { opacity: 0.5; }

	.alerts-list { flex: 1; overflow-y: auto; padding: 12px 20px; }

	.alert-card {
		padding: 16px; border: 1px solid var(--color-border);
		border-left: 3px solid var(--sev-color);
		border-radius: var(--radius-md); margin-bottom: 8px;
	}

	.alert-top {
		display: flex; align-items: center; gap: 8px;
		margin-bottom: 8px; font-size: 13px;
	}

	.alert-severity { font-weight: 600; }
	.alert-type { background: var(--color-surface-hover); padding: 2px 8px; border-radius: var(--radius-full); font-size: 11px; }
	.alert-status { font-size: 12px; color: var(--color-text-secondary); }
	.alert-time { margin-left: auto; color: var(--color-text-secondary); }
	.alert-desc { font-size: 14px; line-height: 1.4; }
	.alert-responders { font-size: 12px; color: var(--color-accent); margin-top: 8px; display: block; }

	.loading, .empty { text-align: center; padding: 40px; color: var(--color-text-secondary); }
</style>
