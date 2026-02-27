<script lang="ts">
	import { onMount } from 'svelte';
	import {
		currentFeedType,
		feedPosts,
		feedLoading,
		feedHasMore,
		loadFeed,
		loadMore,
		createPost,
		verifyPost,
		flagPost,
		type FeedType
	} from '$lib/stores/feed';
	import { trustScore } from '$lib/stores/auth';

	const feedTypes: { type: FeedType; label: string }[] = [
		{ type: 'for_you', label: 'For You' },
		{ type: 'following', label: 'Following' },
		{ type: 'local', label: 'Local' },
		{ type: 'crisis', label: 'Crisis' },
		{ type: 'news', label: 'News' }
	];

	let newPostContent = $state('');
	let showCompose = $state(false);
	let posting = $state(false);

	onMount(() => {
		loadFeed('for_you');
	});

	async function switchFeed(type: FeedType) {
		await loadFeed(type);
	}

	async function submitPost() {
		if (!newPostContent.trim()) return;
		posting = true;
		try {
			await createPost(newPostContent, 'firsthand');
			newPostContent = '';
			showCompose = false;
		} catch {
			// Error handled in store
		} finally {
			posting = false;
		}
	}

	function formatTime(iso: string): string {
		const d = new Date(iso);
		const now = new Date();
		const diffMs = now.getTime() - d.getTime();
		const diffMin = Math.floor(diffMs / 60000);
		if (diffMin < 1) return 'just now';
		if (diffMin < 60) return `${diffMin}m ago`;
		const diffHr = Math.floor(diffMin / 60);
		if (diffHr < 24) return `${diffHr}h ago`;
		const diffDay = Math.floor(diffHr / 24);
		return `${diffDay}d ago`;
	}
</script>

<div class="feed-page">
	<div class="feed-header">
		<h2>Feed</h2>
		{#if ($trustScore ?? 0) >= 25}
			<button class="btn-compose" onclick={() => (showCompose = !showCompose)}>
				{showCompose ? 'Cancel' : 'New Post'}
			</button>
		{/if}
	</div>

	<div class="feed-tabs">
		{#each feedTypes as ft}
			<button
				class="feed-tab"
				class:active={$currentFeedType === ft.type}
				onclick={() => switchFeed(ft.type)}
			>
				{ft.label}
			</button>
		{/each}
	</div>

	{#if showCompose}
		<div class="compose-box">
			<textarea
				bind:value={newPostContent}
				placeholder="Share what's happening..."
				rows="3"
			></textarea>
			<div class="compose-actions">
				<select class="source-select">
					<option value="firsthand">Firsthand</option>
					<option value="aggregated">Aggregated</option>
					<option value="mainstream">Mainstream</option>
				</select>
				<button class="btn-post" onclick={submitPost} disabled={posting || !newPostContent.trim()}>
					{posting ? 'Posting...' : 'Post'}
				</button>
			</div>
		</div>
	{/if}

	<div class="feed-list">
		{#if $feedLoading && $feedPosts.length === 0}
			<div class="loading">Loading feed...</div>
		{:else if $feedPosts.length === 0}
			<div class="empty">No posts yet. Check back later.</div>
		{:else}
			{#each $feedPosts as post (post.id)}
				<div class="post-card">
					<div class="post-header">
						<span class="post-author">{post.user_id.slice(0, 8)}</span>
						<span class="post-source">{post.source_type}</span>
						<span class="post-time">{formatTime(post.created_at)}</span>
					</div>
					<div class="post-content">{post.content}</div>
					<div class="post-actions">
						<button class="post-action" onclick={() => verifyPost(post.id)}>
							Verify {#if post.verification_score}({post.verification_score.toFixed(0)}){/if}
						</button>
						<button class="post-action danger" onclick={() => flagPost(post.id)}>
							Flag
						</button>
					</div>
				</div>
			{/each}

			{#if $feedHasMore}
				<button class="btn-load-more" onclick={loadMore} disabled={$feedLoading}>
					{$feedLoading ? 'Loading...' : 'Load more'}
				</button>
			{/if}
		{/if}
	</div>
</div>

<style>
	.feed-page {
		height: 100%;
		display: flex;
		flex-direction: column;
		overflow: hidden;
	}

	.feed-header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		padding: 16px 20px;
		border-bottom: 1px solid var(--color-border);
	}

	.feed-header h2 {
		font-size: 20px;
		font-weight: 600;
	}

	.btn-compose {
		background: var(--color-accent);
		color: var(--color-bg);
		border: none;
		padding: 8px 16px;
		border-radius: var(--radius-md);
		font-size: 13px;
		font-weight: 600;
	}

	.feed-tabs {
		display: flex;
		gap: 0;
		padding: 0 20px;
		border-bottom: 1px solid var(--color-border);
	}

	.feed-tab {
		background: none;
		border: none;
		padding: 12px 16px;
		color: var(--color-text-secondary);
		font-size: 14px;
		font-weight: 500;
		border-bottom: 2px solid transparent;
		transition: all 0.15s;
	}

	.feed-tab:hover {
		color: var(--color-text);
	}

	.feed-tab.active {
		color: var(--color-accent);
		border-bottom-color: var(--color-accent);
	}

	.compose-box {
		padding: 16px 20px;
		border-bottom: 1px solid var(--color-border);
	}

	.compose-box textarea {
		width: 100%;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-md);
		padding: 12px;
		resize: vertical;
		font-size: 14px;
	}

	.compose-actions {
		display: flex;
		gap: 8px;
		margin-top: 8px;
		justify-content: flex-end;
	}

	.source-select {
		background: var(--color-surface);
		border: 1px solid var(--color-border);
		color: var(--color-text);
		padding: 6px 10px;
		border-radius: var(--radius-sm);
		font-size: 13px;
	}

	.btn-post {
		background: var(--color-accent);
		color: var(--color-bg);
		border: none;
		padding: 8px 20px;
		border-radius: var(--radius-md);
		font-size: 13px;
		font-weight: 600;
	}

	.btn-post:disabled {
		opacity: 0.5;
	}

	.feed-list {
		flex: 1;
		overflow-y: auto;
		padding: 12px 20px;
	}

	.post-card {
		padding: 16px;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-md);
		margin-bottom: 8px;
	}

	.post-header {
		display: flex;
		align-items: center;
		gap: 8px;
		margin-bottom: 8px;
		font-size: 13px;
	}

	.post-author {
		font-weight: 600;
		font-family: var(--font-mono);
	}

	.post-source {
		background: var(--color-surface-hover);
		padding: 2px 8px;
		border-radius: var(--radius-full);
		font-size: 11px;
		color: var(--color-text-secondary);
	}

	.post-time {
		margin-left: auto;
		color: var(--color-text-secondary);
	}

	.post-content {
		font-size: 14px;
		line-height: 1.5;
		margin-bottom: 12px;
		white-space: pre-wrap;
	}

	.post-actions {
		display: flex;
		gap: 8px;
	}

	.post-action {
		background: none;
		border: 1px solid var(--color-border);
		color: var(--color-text-secondary);
		padding: 4px 12px;
		border-radius: var(--radius-sm);
		font-size: 12px;
	}

	.post-action:hover {
		background: var(--color-surface-hover);
	}

	.post-action.danger:hover {
		border-color: var(--color-danger);
		color: var(--color-danger);
	}

	.loading, .empty {
		text-align: center;
		padding: 40px;
		color: var(--color-text-secondary);
	}

	.btn-load-more {
		display: block;
		width: 100%;
		padding: 12px;
		background: none;
		border: 1px solid var(--color-border);
		color: var(--color-text-secondary);
		border-radius: var(--radius-md);
		font-size: 14px;
		margin-top: 8px;
	}

	.btn-load-more:hover {
		background: var(--color-surface-hover);
	}
</style>
