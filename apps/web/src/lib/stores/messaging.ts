import { writable, derived } from 'svelte/store';
import type { Channel, Message } from '$lib/api';
import { listChannels as apiListChannels, getMessages as apiGetMessages, sendMessage as apiSendMessage, createDm as apiCreateDm } from '$lib/api';

export const channels = writable<Channel[]>([]);
export const activeChannelId = writable<string | null>(null);
export const messages = writable<Message[]>([]);
export const messagesLoading = writable(false);
export const channelsLoading = writable(false);

export const activeChannel = derived([channels, activeChannelId], ([$ch, $id]) => $ch.find(c => c.id === $id) ?? null);
export const totalUnread = derived(channels, ($ch) => $ch.reduce((s, c) => s + (c.unread_count ?? 0), 0));

export async function loadChannels() {
	channelsLoading.set(true);
	try { channels.set(await apiListChannels()); }
	catch (e) { console.error('Channels failed:', e); }
	finally { channelsLoading.set(false); }
}

export async function selectChannel(channelId: string) {
	activeChannelId.set(channelId);
	messagesLoading.set(true);
	try { messages.set(await apiGetMessages(channelId)); }
	catch (e) { console.error('Messages failed:', e); }
	finally { messagesLoading.set(false); }
}

export async function sendMessage(content: string) {
	let channelId: string | null = null;
	activeChannelId.subscribe(v => channelId = v)();
	if (!channelId) return;
	await apiSendMessage(channelId, content);
	messages.set(await apiGetMessages(channelId));
}

export async function createDm(userId: string) {
	const channel = await apiCreateDm(userId);
	await loadChannels();
	await selectChannel(channel.id);
	return channel;
}
