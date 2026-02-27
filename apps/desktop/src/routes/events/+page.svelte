<script lang="ts">
	import { onMount } from 'svelte';
	import { events, eventsLoading, loadEvents, createEvent } from '$lib/stores/events';
	import { trustScore } from '$lib/stores/auth';

	let showCreate = $state(false);
	let newEvent = $state({ title: '', description: '', starts_at: '', location_visibility: 'public' });
	let creating = $state(false);

	onMount(() => {
		loadEvents();
	});

	async function handleCreate() {
		if (!newEvent.title.trim() || !newEvent.starts_at) return;
		creating = true;
		try {
			await createEvent(newEvent);
			showCreate = false;
			newEvent = { title: '', description: '', starts_at: '', location_visibility: 'public' };
		} catch {
			// Error handled in store
		} finally {
			creating = false;
		}
	}

	function formatDate(iso: string): string {
		return new Date(iso).toLocaleDateString([], {
			weekday: 'short',
			month: 'short',
			day: 'numeric',
			hour: '2-digit',
			minute: '2-digit'
		});
	}
</script>

<div class="events-page">
	<div class="events-header">
		<h2>Events</h2>
		{#if ($trustScore ?? 0) >= 50}
			<button class="btn-create" onclick={() => (showCreate = !showCreate)}>
				{showCreate ? 'Cancel' : 'Create Event'}
			</button>
		{/if}
	</div>

	{#if showCreate}
		<div class="create-form">
			<input type="text" bind:value={newEvent.title} placeholder="Event title" />
			<textarea bind:value={newEvent.description} placeholder="Description (optional)" rows="2"></textarea>
			<input type="datetime-local" bind:value={newEvent.starts_at} />
			<select bind:value={newEvent.location_visibility}>
				<option value="public">Public location</option>
				<option value="rsvp">Visible after RSVP</option>
				<option value="timed">Revealed at event time</option>
			</select>
			<button class="btn-submit" onclick={handleCreate} disabled={creating}>
				{creating ? 'Creating...' : 'Create'}
			</button>
		</div>
	{/if}

	<div class="events-list">
		{#if $eventsLoading}
			<div class="loading">Loading events...</div>
		{:else if $events.length === 0}
			<div class="empty">No upcoming events</div>
		{:else}
			{#each $events as event (event.id)}
				<div class="event-card">
					<div class="event-date">{formatDate(event.starts_at)}</div>
					<h3 class="event-title">{event.title}</h3>
					{#if event.description}
						<p class="event-desc">{event.description}</p>
					{/if}
					<div class="event-meta">
						<span class="event-visibility">{event.location_visibility}</span>
						{#if event.rsvp_count}
							<span class="event-rsvp">{event.rsvp_count} attending</span>
						{/if}
					</div>
				</div>
			{/each}
		{/if}
	</div>
</div>

<style>
	.events-page {
		height: 100%;
		display: flex;
		flex-direction: column;
	}

	.events-header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: 16px 20px;
		border-bottom: 1px solid var(--color-border);
	}

	.events-header h2 { font-size: 20px; font-weight: 600; }

	.btn-create {
		background: var(--color-accent);
		color: var(--color-bg);
		border: none;
		padding: 8px 16px;
		border-radius: var(--radius-md);
		font-size: 13px;
		font-weight: 600;
	}

	.create-form {
		padding: 16px 20px;
		border-bottom: 1px solid var(--color-border);
		display: flex;
		flex-direction: column;
		gap: 8px;
	}

	.create-form input, .create-form textarea, .create-form select {
		border: 1px solid var(--color-border);
		border-radius: var(--radius-md);
		padding: 10px 12px;
		font-size: 14px;
	}

	.btn-submit {
		background: var(--color-accent);
		color: var(--color-bg);
		border: none;
		padding: 10px;
		border-radius: var(--radius-md);
		font-size: 14px;
		font-weight: 600;
		align-self: flex-end;
	}

	.btn-submit:disabled { opacity: 0.5; }

	.events-list {
		flex: 1;
		overflow-y: auto;
		padding: 12px 20px;
	}

	.event-card {
		padding: 16px;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-md);
		margin-bottom: 8px;
	}

	.event-date {
		font-size: 12px;
		color: var(--color-accent);
		font-weight: 600;
		margin-bottom: 4px;
	}

	.event-title { font-size: 16px; font-weight: 600; margin-bottom: 4px; }
	.event-desc { font-size: 14px; color: var(--color-text-secondary); margin-bottom: 8px; }

	.event-meta {
		display: flex;
		gap: 12px;
		font-size: 12px;
		color: var(--color-text-secondary);
	}

	.event-visibility {
		background: var(--color-surface-hover);
		padding: 2px 8px;
		border-radius: var(--radius-full);
	}

	.loading, .empty { text-align: center; padding: 40px; color: var(--color-text-secondary); }
</style>
