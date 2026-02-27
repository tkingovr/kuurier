import { writable } from 'svelte/store';
import { listEvents as apiListEvents, createEvent as apiCreateEvent } from '$lib/api';

export interface KuurierEvent {
	id: string;
	title: string;
	description: string | null;
	starts_at: string;
	ends_at: string | null;
	location_visibility: string;
	channel_id: string | null;
	created_at: string;
	rsvp_count?: number;
	user_rsvp?: boolean;
}

export const events = writable<KuurierEvent[]>([]);
export const eventsLoading = writable(false);

export async function loadEvents() {
	eventsLoading.set(true);
	try {
		const response = (await apiListEvents()) as { events?: KuurierEvent[] };
		events.set(response?.events ?? []);
	} catch (e) {
		console.error('Failed to load events:', e);
	} finally {
		eventsLoading.set(false);
	}
}

export async function createEvent(eventData: Record<string, unknown>) {
	try {
		await apiCreateEvent(eventData);
		await loadEvents();
	} catch (e) {
		console.error('Failed to create event:', e);
		throw e;
	}
}
