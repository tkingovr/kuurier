import { writable } from 'svelte/store';
import { listAlerts as apiListAlerts, createAlert as apiCreateAlert } from '$lib/api';

export interface SosAlert {
	id: string;
	user_id: string;
	alert_type: string;
	description: string;
	severity: number;
	status: string;
	created_at: string;
	responder_count?: number;
}

export const alerts = writable<SosAlert[]>([]);
export const alertsLoading = writable(false);

export async function loadAlerts() {
	alertsLoading.set(true);
	try {
		const response = (await apiListAlerts()) as { alerts?: SosAlert[] };
		alerts.set(response?.alerts ?? []);
	} catch (e) {
		console.error('Failed to load alerts:', e);
	} finally {
		alertsLoading.set(false);
	}
}

export async function createAlert(alertData: Record<string, unknown>) {
	try {
		await apiCreateAlert(alertData);
		await loadAlerts();
	} catch (e) {
		console.error('Failed to create alert:', e);
		throw e;
	}
}
