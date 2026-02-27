import { invoke } from '@tauri-apps/api/core';

// ========== Types ==========

export interface AuthState {
	is_authenticated: boolean;
	user_id: string | null;
	trust_score: number | null;
	device_id: string | null;
}

export interface QrCodeData {
	desktop_pub_key: string;
	secret: string;
	device_id: string;
	qr_image: string;
}

export interface TorStatus {
	status: 'Disabled' | 'Connecting' | 'Bootstrapping' | 'Connected' | 'Error';
	detail?: string | number;
}

export interface Channel {
	id: string;
	name: string | null;
	channel_type: string;
	org_id: string | null;
	created_at: string;
	unread_count: number;
	last_message: unknown;
	members: unknown[];
	other_user_id: string | null;
	other_user_display_name: string | null;
}

export interface Message {
	id: string;
	channel_id: string;
	sender_id: string;
	sender_display_name: string | null;
	ciphertext: string | null;
	content: string | null;
	message_type: string;
	reply_to_id: string | null;
	created_at: string;
	updated_at: string | null;
}

export interface Post {
	id: string;
	user_id: string;
	content: string;
	source_type: string;
	verification_score: number | null;
	created_at: string;
}

export interface AppConfig {
	api_base_url: string;
	tor_enabled: boolean;
	socks_port: number;
}

// ========== Auth API ==========

export async function getAuthStatus(): Promise<AuthState> {
	return invoke('get_auth_status');
}

export async function startDeviceLink(): Promise<QrCodeData> {
	return invoke('start_device_link');
}

export async function pollDeviceLink(deviceId: string): Promise<{ linked: boolean; user_id: string } | null> {
	return invoke('poll_device_link', { deviceId });
}

export async function tryRestoreSession(): Promise<boolean> {
	return invoke('try_restore_session');
}

export async function logout(): Promise<void> {
	return invoke('logout');
}

export async function panicWipe(): Promise<void> {
	return invoke('panic_wipe');
}

// ========== Profile API ==========

export async function getMe(): Promise<{
	id: string;
	trust_score: number;
	is_verified: boolean;
	display_name: string | null;
}> {
	return invoke('get_me');
}

export async function setDisplayName(name: string): Promise<{ display_name: string }> {
	return invoke('set_display_name', { name });
}

// ========== Tor API ==========

export async function getTorStatus(): Promise<TorStatus> {
	return invoke('get_tor_status');
}

export async function restartTor(): Promise<TorStatus> {
	return invoke('restart_tor');
}

export async function setTorEnabled(enabled: boolean): Promise<TorStatus> {
	return invoke('set_tor_enabled', { enabled });
}

// ========== Feed API ==========

export async function fetchFeed(feedType: string, offset: number = 0): Promise<unknown> {
	return invoke('fetch_feed', { feedType, offset });
}

export async function createPost(content: string, sourceType: string): Promise<unknown> {
	return invoke('create_post', { content, sourceType });
}

export async function verifyPost(id: string): Promise<unknown> {
	return invoke('verify_post', { id });
}

export async function flagPost(id: string): Promise<unknown> {
	return invoke('flag_post', { id });
}

// ========== Messaging API ==========

export async function listChannels(): Promise<Channel[]> {
	return invoke('list_channels');
}

export async function getMessages(channelId: string, before?: string): Promise<Message[]> {
	return invoke('get_messages', { channelId, before });
}

export async function sendMessage(channelId: string, content: string): Promise<unknown> {
	return invoke('send_message', { channelId, content });
}

export async function createDm(userId: string): Promise<{ channel_id: string; other_user_id: string }> {
	return invoke('create_dm', { userId });
}

// ========== Events API ==========

export async function listEvents(): Promise<unknown> {
	return invoke('list_events');
}

export async function createEvent(event: Record<string, unknown>): Promise<unknown> {
	return invoke('create_event', { event });
}

// ========== Alerts API ==========

export async function listAlerts(): Promise<unknown> {
	return invoke('list_alerts');
}

export async function createAlert(alert: Record<string, unknown>): Promise<unknown> {
	return invoke('create_alert', { alert });
}

// ========== Settings API ==========

export async function getConfig(): Promise<AppConfig> {
	return invoke('get_config');
}

export async function setApiUrl(url: string): Promise<void> {
	return invoke('set_api_url', { url });
}
