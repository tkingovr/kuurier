import { writable, derived } from 'svelte/store';
import type { Channel, Message } from '$lib/api';
import {
	listChannels as apiListChannels,
	getMessages as apiGetMessages,
	sendMessage as apiSendMessage,
	createDm as apiCreateDm
} from '$lib/api';

export const channels = writable<Channel[]>([]);
export const activeChannelId = writable<string | null>(null);
export const messages = writable<Message[]>([]);
export const messagesLoading = writable(false);
export const channelsLoading = writable(false);

export const activeChannel = derived(
	[channels, activeChannelId],
	([$channels, $id]) => $channels.find((c) => c.id === $id) ?? null
);

export const totalUnread = derived(channels, ($channels) =>
	$channels.reduce((sum, ch) => sum + (ch.unread_count ?? 0), 0)
);

export async function loadChannels() {
	channelsLoading.set(true);
	try {
		const result = await apiListChannels();
		channels.set(Array.isArray(result) ? result : []);
	} catch (e) {
		console.error('Failed to load channels:', e);
	} finally {
		channelsLoading.set(false);
	}
}

export async function selectChannel(channelId: string) {
	activeChannelId.set(channelId);
	messagesLoading.set(true);
	try {
		const result = await apiGetMessages(channelId);
		messages.set(Array.isArray(result) ? result : []);
	} catch (e) {
		console.error('Failed to load messages:', e);
	} finally {
		messagesLoading.set(false);
	}
}

export async function loadMoreMessages() {
	let channelId: string | null = null;
	activeChannelId.subscribe((v) => (channelId = v))();
	if (!channelId) return;

	let currentMessages: Message[] = [];
	messages.subscribe((v) => (currentMessages = v))();
	const oldest = currentMessages[currentMessages.length - 1];
	if (!oldest) return;

	messagesLoading.set(true);
	try {
		const older = await apiGetMessages(channelId, oldest.created_at);
		if (Array.isArray(older) && older.length > 0) {
			messages.update((current) => [...current, ...older]);
		}
	} catch (e) {
		console.error('Failed to load more messages:', e);
	} finally {
		messagesLoading.set(false);
	}
}

export async function sendMessage(content: string) {
	let channelId: string | null = null;
	activeChannelId.subscribe((v) => (channelId = v))();
	if (!channelId) return;

	try {
		await apiSendMessage(channelId, content);
		// The message will arrive via WebSocket; for now, reload
		const result = await apiGetMessages(channelId);
		messages.set(Array.isArray(result) ? result : []);
	} catch (e) {
		console.error('Failed to send message:', e);
		throw e;
	}
}

export async function createDm(userId: string) {
	try {
		const channel = await apiCreateDm(userId);
		await loadChannels();
		await selectChannel(channel.id);
		return channel;
	} catch (e) {
		console.error('Failed to create DM:', e);
		throw e;
	}
}

export function addIncomingMessage(message: Message) {
	let currentChannelId: string | null = null;
	activeChannelId.subscribe((v) => (currentChannelId = v))();

	if (message.channel_id === currentChannelId) {
		messages.update((current) => [message, ...current]);
	}

	// Update unread count for other channels
	channels.update((chs) =>
		chs.map((ch) => {
			if (ch.id === message.channel_id && ch.id !== currentChannelId) {
				return { ...ch, unread_count: (ch.unread_count ?? 0) + 1 };
			}
			return ch;
		})
	);
}
