/**
 * Web app API client — communicates directly with the Kuurier server via fetch.
 * Unlike the desktop app (which routes through Rust/Tauri IPC), the web app
 * calls the HTTP API directly. Tor routing is NOT available in the browser —
 * users should use Tor Browser for IP privacy.
 *
 * Crypto operations use the WebCrypto API for Ed25519 key management.
 */

const API_BASE = '/api/v1';

// ========== Types (shared with desktop) ==========

export interface AuthState {
	is_authenticated: boolean;
	user_id: string | null;
	trust_score: number | null;
	token: string | null;
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

// ========== Token Management ==========

let authToken: string | null = null;

export function setToken(token: string | null) {
	authToken = token;
	if (token) {
		sessionStorage.setItem('kuurier_token', token);
	} else {
		sessionStorage.removeItem('kuurier_token');
	}
}

export function getToken(): string | null {
	if (!authToken) {
		authToken = sessionStorage.getItem('kuurier_token');
	}
	return authToken;
}

// ========== HTTP Helpers ==========

async function apiGet(path: string): Promise<unknown> {
	const token = getToken();
	const resp = await fetch(`${API_BASE}${path}`, {
		headers: token ? { Authorization: `Bearer ${token}` } : {}
	});
	if (!resp.ok) {
		const body = await resp.json().catch(() => ({}));
		throw new Error((body as { error?: string }).error || `HTTP ${resp.status}`);
	}
	return resp.json();
}

async function apiPost(path: string, body?: unknown): Promise<unknown> {
	const token = getToken();
	const resp = await fetch(`${API_BASE}${path}`, {
		method: 'POST',
		headers: {
			'Content-Type': 'application/json',
			...(token ? { Authorization: `Bearer ${token}` } : {})
		},
		body: body ? JSON.stringify(body) : undefined
	});
	if (!resp.ok) {
		const respBody = await resp.json().catch(() => ({}));
		throw new Error((respBody as { error?: string }).error || `HTTP ${resp.status}`);
	}
	return resp.json();
}

async function apiPut(path: string, body?: unknown): Promise<unknown> {
	const token = getToken();
	const resp = await fetch(`${API_BASE}${path}`, {
		method: 'PUT',
		headers: {
			'Content-Type': 'application/json',
			...(token ? { Authorization: `Bearer ${token}` } : {})
		},
		body: body ? JSON.stringify(body) : undefined
	});
	if (!resp.ok) {
		const respBody = await resp.json().catch(() => ({}));
		throw new Error((respBody as { error?: string }).error || `HTTP ${resp.status}`);
	}
	return resp.json();
}

async function apiDelete(path: string): Promise<unknown> {
	const token = getToken();
	const resp = await fetch(`${API_BASE}${path}`, {
		method: 'DELETE',
		headers: token ? { Authorization: `Bearer ${token}` } : {}
	});
	if (!resp.ok) {
		const body = await resp.json().catch(() => ({}));
		throw new Error((body as { error?: string }).error || `HTTP ${resp.status}`);
	}
	return resp.json();
}

// ========== Auth ==========

export async function authRegister(
	publicKeyBase64: string,
	inviteCode: string
): Promise<{ user_id: string; challenge: string; challenge_mac: string }> {
	return apiPost('/auth/register', {
		public_key: publicKeyBase64,
		invite_code: inviteCode
	}) as Promise<{ user_id: string; challenge: string; challenge_mac: string }>;
}

export async function authVerify(
	userId: string,
	challenge: string,
	signatureBase64: string
): Promise<{ token: string; user_id: string; trust_score: number }> {
	return apiPost('/auth/verify', {
		user_id: userId,
		challenge,
		signature: signatureBase64
	}) as Promise<{ token: string; user_id: string; trust_score: number }>;
}

export async function getMe(): Promise<{
	id: string;
	trust_score: number;
	is_verified: boolean;
	display_name: string | null;
}> {
	return apiGet('/me') as Promise<{ id: string; trust_score: number; is_verified: boolean; display_name: string | null }>;
}

export async function setDisplayName(name: string): Promise<{ display_name: string }> {
	return apiPut('/me/display-name', { display_name: name }) as Promise<{ display_name: string }>;
}

// ========== Feed ==========

export async function fetchFeed(feedType: string, offset = 0): Promise<unknown> {
	return apiGet(`/feed/v2?feed_type=${feedType}&offset=${offset}`);
}

export async function createPost(content: string, sourceType: string): Promise<unknown> {
	return apiPost('/feed/posts', { content, source_type: sourceType });
}

export async function verifyPost(id: string): Promise<unknown> {
	return apiPost(`/feed/posts/${id}/verify`);
}

export async function flagPost(id: string): Promise<unknown> {
	return apiPost(`/feed/posts/${id}/flag`);
}

// ========== Messaging ==========

export async function listChannels(): Promise<Channel[]> {
	const resp = (await apiGet('/channels')) as { channels?: Channel[] };
	return resp.channels ?? [];
}

export async function getMessages(channelId: string, before?: string): Promise<Message[]> {
	const path = before
		? `/messages/${channelId}?before=${before}`
		: `/messages/${channelId}`;
	const resp = (await apiGet(path)) as { messages?: Message[] };
	return resp.messages ?? [];
}

export async function sendMessage(channelId: string, ciphertext: string): Promise<unknown> {
	return apiPost('/messages', {
		channel_id: channelId,
		ciphertext,
		message_type: 'text'
	});
}

export async function createDm(userId: string): Promise<Channel> {
	return apiPost('/channels/dm', { user_id: userId }) as Promise<Channel>;
}

// ========== Events ==========

export async function listEvents(): Promise<unknown> {
	return apiGet('/events');
}

export async function createEvent(event: Record<string, unknown>): Promise<unknown> {
	return apiPost('/events', event);
}

// ========== Alerts ==========

export async function listAlerts(): Promise<unknown> {
	return apiGet('/alerts');
}

export async function createAlert(alert: Record<string, unknown>): Promise<unknown> {
	return apiPost('/alerts', alert);
}

// ========== WebCrypto Ed25519 Key Management ==========

/**
 * Generate an Ed25519 keypair using WebCrypto.
 * Returns the keypair as raw byte arrays.
 */
export async function generateEd25519Keypair(): Promise<{
	publicKey: Uint8Array;
	privateKey: Uint8Array;
}> {
	const keypair = await crypto.subtle.generateKey('Ed25519', true, ['sign', 'verify']);
	const publicKeyBuffer = await crypto.subtle.exportKey('raw', keypair.publicKey);
	const privateKeyBuffer = await crypto.subtle.exportKey('pkcs8', keypair.privateKey);
	return {
		publicKey: new Uint8Array(publicKeyBuffer),
		privateKey: new Uint8Array(privateKeyBuffer)
	};
}

/**
 * Sign a challenge with the Ed25519 private key.
 */
export async function signChallenge(
	privateKeyPkcs8: Uint8Array,
	challenge: string
): Promise<Uint8Array> {
	const key = await crypto.subtle.importKey('pkcs8', privateKeyPkcs8, 'Ed25519', false, [
		'sign'
	]);
	const encoded = new TextEncoder().encode(challenge);
	const signature = await crypto.subtle.sign('Ed25519', key, encoded);
	return new Uint8Array(signature);
}

// ========== Base64 Helpers ==========

export function toBase64(bytes: Uint8Array): string {
	let binary = '';
	for (const byte of bytes) {
		binary += String.fromCharCode(byte);
	}
	return btoa(binary);
}

export function toBase64Url(bytes: Uint8Array): string {
	return toBase64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function fromBase64Url(str: string): Uint8Array {
	const base64 = str.replace(/-/g, '+').replace(/_/g, '/');
	const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
	const binary = atob(padded);
	const bytes = new Uint8Array(binary.length);
	for (let i = 0; i < binary.length; i++) {
		bytes[i] = binary.charCodeAt(i);
	}
	return bytes;
}
