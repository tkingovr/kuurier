<script lang="ts">
	import { onMount } from 'svelte';
	import {
		channels,
		activeChannelId,
		activeChannel,
		messages,
		messagesLoading,
		channelsLoading,
		loadChannels,
		selectChannel,
		sendMessage
	} from '$lib/stores/messaging';
	import { authState } from '$lib/stores/auth';

	let messageInput = $state('');
	let sending = $state(false);

	onMount(() => {
		loadChannels();
	});

	async function handleSelectChannel(channelId: string) {
		await selectChannel(channelId);
	}

	async function handleSend() {
		if (!messageInput.trim() || sending) return;
		sending = true;
		try {
			await sendMessage(messageInput);
			messageInput = '';
		} catch {
			// Error handled in store
		} finally {
			sending = false;
		}
	}

	function handleKeydown(e: KeyboardEvent) {
		if (e.key === 'Enter' && !e.shiftKey) {
			e.preventDefault();
			handleSend();
		}
	}

	function formatTime(iso: string): string {
		return new Date(iso).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
	}

	function channelName(ch: { name: string | null; channel_type: string; id: string; other_user_display_name?: string | null }): string {
		if (ch.channel_type === 'dm' && ch.other_user_display_name) return ch.other_user_display_name;
		if (ch.name) return ch.name;
		if (ch.channel_type === 'dm') return `DM ${ch.id.slice(0, 8)}`;
		return ch.id.slice(0, 8);
	}

	function senderLabel(msg: { sender_id: string; sender_display_name: string | null }): string {
		return msg.sender_display_name || msg.sender_id.slice(0, 8);
	}

	function isOwnMessage(senderId: string): boolean {
		return senderId === $authState.user_id;
	}

	// Deterministic color from user ID for visual differentiation in group chats
	const USER_COLORS = [
		'#f97316', '#3b82f6', '#10b981', '#8b5cf6', '#ef4444',
		'#06b6d4', '#f59e0b', '#ec4899', '#14b8a6', '#6366f1'
	];

	function userColor(userId: string): string {
		let hash = 0;
		for (let i = 0; i < userId.length; i++) {
			hash = ((hash << 5) - hash + userId.charCodeAt(i)) | 0;
		}
		return USER_COLORS[((hash % USER_COLORS.length) + USER_COLORS.length) % USER_COLORS.length];
	}
</script>

<div class="messages-page">
	<div class="channel-list">
		<div class="channel-list-header">
			<h3>Channels</h3>
		</div>
		<div class="channel-items">
			{#if $channelsLoading}
				<div class="loading">Loading...</div>
			{:else if $channels.length === 0}
				<div class="empty">No channels yet</div>
			{:else}
				{#each $channels as ch (ch.id)}
					<button
						class="channel-item"
						class:active={$activeChannelId === ch.id}
						onclick={() => handleSelectChannel(ch.id)}
					>
						<span class="channel-icon">{ch.channel_type === 'dm' ? '👤' : '#'}</span>
						<span class="channel-name">{channelName(ch)}</span>
						{#if (ch.unread_count ?? 0) > 0}
							<span class="channel-badge">{ch.unread_count}</span>
						{/if}
					</button>
				{/each}
			{/if}
		</div>
	</div>

	<div class="message-pane">
		{#if !$activeChannel}
			<div class="no-channel">
				<p>Select a channel to start messaging</p>
			</div>
		{:else}
			<div class="message-header">
				<span class="message-header-icon">{$activeChannel.channel_type === 'dm' ? '👤' : '#'}</span>
				<h3>{channelName($activeChannel)}</h3>
			</div>

			<div class="message-list">
				{#if $messagesLoading && $messages.length === 0}
					<div class="loading">Loading messages...</div>
				{:else if $messages.length === 0}
					<div class="empty">No messages yet. Say hello!</div>
				{:else}
					{#each [...$messages].reverse() as msg (msg.id)}
						{@const own = isOwnMessage(msg.sender_id)}
						<div class="message" class:own>
							{#if !own}
								<div class="message-meta">
									<span class="message-sender" style:color={userColor(msg.sender_id)}>
										{senderLabel(msg)}
									</span>
									<span class="message-time">{formatTime(msg.created_at)}</span>
								</div>
							{/if}
							<div class="message-bubble" class:own>
								<div class="message-body">{msg.content ?? '[encrypted]'}</div>
							</div>
							{#if own}
								<span class="message-time own-time">{formatTime(msg.created_at)}</span>
							{/if}
						</div>
					{/each}
				{/if}
			</div>

			<div class="compose-bar">
				<textarea
					bind:value={messageInput}
					onkeydown={handleKeydown}
					placeholder="Type a message..."
					rows="1"
				></textarea>
				<button class="btn-send" onclick={handleSend} disabled={sending || !messageInput.trim()}>
					Send
				</button>
			</div>
		{/if}
	</div>
</div>

<style>
	.messages-page {
		display: flex;
		height: 100%;
	}

	.channel-list {
		width: 260px;
		border-right: 1px solid var(--color-border);
		display: flex;
		flex-direction: column;
		flex-shrink: 0;
	}

	.channel-list-header {
		padding: 16px;
		border-bottom: 1px solid var(--color-border);
	}

	.channel-list-header h3 {
		font-size: 16px;
		font-weight: 600;
	}

	.channel-items {
		flex: 1;
		overflow-y: auto;
		padding: 4px;
	}

	.channel-item {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 10px 12px;
		border: none;
		background: none;
		width: 100%;
		text-align: left;
		border-radius: var(--radius-md);
		color: var(--color-text);
		font-size: 14px;
		transition: background 0.1s;
	}

	.channel-item:hover {
		background: var(--color-surface-hover);
	}

	.channel-item.active {
		background: var(--color-surface-hover);
		color: var(--color-accent);
	}

	.channel-icon {
		width: 20px;
		text-align: center;
		flex-shrink: 0;
	}

	.channel-name {
		flex: 1;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.channel-badge {
		background: var(--color-accent);
		color: var(--color-bg);
		font-size: 11px;
		font-weight: 600;
		padding: 1px 6px;
		border-radius: var(--radius-full);
		min-width: 16px;
		text-align: center;
	}

	.message-pane {
		flex: 1;
		display: flex;
		flex-direction: column;
	}

	.no-channel {
		flex: 1;
		display: flex;
		align-items: center;
		justify-content: center;
		color: var(--color-text-secondary);
	}

	.message-header {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 16px 20px;
		border-bottom: 1px solid var(--color-border);
	}

	.message-header h3 {
		font-size: 16px;
		font-weight: 600;
	}

	.message-header-icon {
		font-size: 18px;
	}

	.message-list {
		flex: 1;
		overflow-y: auto;
		padding: 16px 20px;
		display: flex;
		flex-direction: column;
		gap: 6px;
	}

	.message {
		display: flex;
		flex-direction: column;
		align-items: flex-start;
		max-width: 75%;
	}

	.message.own {
		align-items: flex-end;
		align-self: flex-end;
	}

	.message-meta {
		display: flex;
		gap: 8px;
		align-items: baseline;
		margin-bottom: 2px;
	}

	.message-sender {
		font-weight: 600;
		font-size: 13px;
		font-family: var(--font-mono);
	}

	.message-time {
		font-size: 11px;
		color: var(--color-text-secondary);
	}

	.own-time {
		margin-top: 2px;
	}

	.message-bubble {
		background: var(--color-surface);
		border: 1px solid var(--color-border);
		border-radius: var(--radius-lg);
		padding: 8px 12px;
	}

	.message-bubble.own {
		background: color-mix(in srgb, var(--color-accent) 15%, var(--color-surface));
		border-color: color-mix(in srgb, var(--color-accent) 30%, var(--color-border));
	}

	.message-body {
		font-size: 14px;
		line-height: 1.4;
		white-space: pre-wrap;
		word-break: break-word;
	}

	.compose-bar {
		display: flex;
		gap: 8px;
		padding: 12px 20px;
		border-top: 1px solid var(--color-border);
		align-items: flex-end;
	}

	.compose-bar textarea {
		flex: 1;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-md);
		padding: 10px 12px;
		font-size: 14px;
		resize: none;
		max-height: 120px;
	}

	.btn-send {
		background: var(--color-accent);
		color: var(--color-bg);
		border: none;
		padding: 10px 20px;
		border-radius: var(--radius-md);
		font-size: 14px;
		font-weight: 600;
		flex-shrink: 0;
	}

	.btn-send:disabled {
		opacity: 0.5;
	}

	.loading, .empty {
		text-align: center;
		padding: 40px;
		color: var(--color-text-secondary);
		font-size: 14px;
	}
</style>
