import { writable, derived } from 'svelte/store';
import type { TorStatus } from '$lib/api';
import { getTorStatus, setTorEnabled, restartTor } from '$lib/api';

export const torStatus = writable<TorStatus>({ status: 'Disabled' });
export const wsConnected = writable(false);

export const isOnline = derived(
	[torStatus, wsConnected],
	([$tor, $ws]) => $tor.status === 'Connected' || $tor.status === 'Disabled'
);

export const connectionLabel = derived(torStatus, ($tor) => {
	switch ($tor.status) {
		case 'Disabled':
			return 'Direct connection';
		case 'Connecting':
			return 'Connecting to Tor...';
		case 'Bootstrapping':
			return `Tor bootstrapping ${$tor.detail}%`;
		case 'Connected':
			return 'Connected via Tor';
		case 'Error':
			return `Tor error: ${$tor.detail}`;
		default:
			return 'Unknown';
	}
});

export async function refreshTorStatus() {
	try {
		const status = await getTorStatus();
		torStatus.set(status);
	} catch (e) {
		console.error('Failed to get Tor status:', e);
	}
}

export async function toggleTor(enabled: boolean) {
	try {
		const status = await setTorEnabled(enabled);
		torStatus.set(status);
	} catch (e) {
		console.error('Failed to toggle Tor:', e);
	}
}

export async function reconnectTor() {
	try {
		const status = await restartTor();
		torStatus.set(status);
	} catch (e) {
		console.error('Failed to restart Tor:', e);
	}
}
