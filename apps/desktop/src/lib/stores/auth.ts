import { writable, derived } from 'svelte/store';
import type { AuthState } from '$lib/api';
import { getAuthStatus, tryRestoreSession, logout as apiLogout, panicWipe as apiPanicWipe, startDeviceLink, pollDeviceLink } from '$lib/api';

export const authState = writable<AuthState>({
	is_authenticated: false,
	user_id: null,
	trust_score: null,
	device_id: null
});

export const isAuthenticated = derived(authState, ($auth) => $auth.is_authenticated);
export const userId = derived(authState, ($auth) => $auth.user_id);
export const trustScore = derived(authState, ($auth) => $auth.trust_score);

export async function initAuth(): Promise<boolean> {
	try {
		const restored = await tryRestoreSession();
		if (restored) {
			const status = await getAuthStatus();
			authState.set(status);
			return true;
		}
		return false;
	} catch (e) {
		console.error('Auth init failed:', e);
		return false;
	}
}

export async function startLinking() {
	return startDeviceLink();
}

export async function checkLinkStatus(deviceId: string) {
	const result = await pollDeviceLink(deviceId);
	if (result?.linked) {
		const status = await getAuthStatus();
		authState.set(status);
		return true;
	}
	return false;
}

export async function logout() {
	await apiLogout();
	authState.set({
		is_authenticated: false,
		user_id: null,
		trust_score: null,
		device_id: null
	});
}

export async function panicWipe() {
	await apiPanicWipe();
	authState.set({
		is_authenticated: false,
		user_id: null,
		trust_score: null,
		device_id: null
	});
}
