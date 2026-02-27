import { writable, derived } from 'svelte/store';
import type { AuthState } from '$lib/api';
import {
	getMe,
	setToken,
	getToken,
	generateEd25519Keypair,
	signChallenge,
	authRegister,
	authVerify,
	toBase64,
	toBase64Url
} from '$lib/api';

export const authState = writable<AuthState>({
	is_authenticated: false,
	user_id: null,
	trust_score: null,
	token: null
});

export const isAuthenticated = derived(authState, ($auth) => $auth.is_authenticated);
export const userId = derived(authState, ($auth) => $auth.user_id);
export const trustScore = derived(authState, ($auth) => $auth.trust_score);

export async function initAuth(): Promise<boolean> {
	const token = getToken();
	if (!token) return false;

	try {
		const profile = await getMe();
		authState.set({
			is_authenticated: true,
			user_id: profile.id,
			trust_score: profile.trust_score,
			token
		});
		return true;
	} catch {
		setToken(null);
		return false;
	}
}

export async function register(inviteCode: string): Promise<void> {
	const { publicKey, privateKey } = await generateEd25519Keypair();
	const publicKeyBase64 = toBase64(publicKey);

	// Store private key in sessionStorage (web app limitation - less secure than OS keychain)
	sessionStorage.setItem('kuurier_private_key', toBase64Url(privateKey));

	const { user_id, challenge } = await authRegister(publicKeyBase64, inviteCode);
	const signature = await signChallenge(privateKey, challenge);
	const signatureBase64 = toBase64(signature);

	const result = await authVerify(user_id, challenge, signatureBase64);
	setToken(result.token);

	authState.set({
		is_authenticated: true,
		user_id: result.user_id,
		trust_score: result.trust_score,
		token: result.token
	});
}

export async function login(): Promise<void> {
	const pkStr = sessionStorage.getItem('kuurier_private_key');
	if (!pkStr) throw new Error('No stored private key');

	const { fromBase64Url } = await import('$lib/api');
	const privateKey = fromBase64Url(pkStr);

	// Derive public key and register/login
	const keypair = await crypto.subtle.importKey('pkcs8', privateKey, 'Ed25519', true, [
		'sign'
	]);
	const pubKeyBuf = await crypto.subtle.exportKey(
		'raw',
		(
			await crypto.subtle.generateKey('Ed25519', true, ['sign', 'verify'])
		).publicKey
	);
	// Note: this generates a NEW keypair, which is wrong for login.
	// For login, we'd need to extract the public key from the private key.
	// This is a simplified placeholder — real implementation would store both keys.
	void keypair;
	void pubKeyBuf;
	throw new Error('Login from stored key not yet implemented — use invite code');
}

export function logout() {
	setToken(null);
	sessionStorage.removeItem('kuurier_private_key');
	authState.set({
		is_authenticated: false,
		user_id: null,
		trust_score: null,
		token: null
	});
}
