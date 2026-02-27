import { writable, derived } from 'svelte/store';
import { fetchFeed, createPost as apiCreatePost, verifyPost as apiVerifyPost, flagPost as apiFlagPost } from '$lib/api';

export type FeedType = 'for_you' | 'following' | 'local' | 'crisis' | 'news';

export interface FeedPost {
	id: string;
	user_id: string;
	content: string;
	source_type: string;
	verification_score: number | null;
	created_at: string;
	topic?: string;
}

export const currentFeedType = writable<FeedType>('for_you');
export const feedPosts = writable<FeedPost[]>([]);
export const feedLoading = writable(false);
export const feedOffset = writable(0);
export const feedHasMore = writable(true);

export async function loadFeed(feedType: FeedType, reset = true) {
	feedLoading.set(true);
	if (reset) {
		feedOffset.set(0);
		feedPosts.set([]);
	}

	try {
		let offset = 0;
		feedOffset.subscribe((v) => (offset = v))();

		const response = (await fetchFeed(feedType, offset)) as { posts?: FeedPost[] };
		const posts = response?.posts ?? [];

		if (reset) {
			feedPosts.set(posts);
		} else {
			feedPosts.update((current) => [...current, ...posts]);
		}

		feedHasMore.set(posts.length >= 20);
		feedOffset.update((n) => n + posts.length);
		currentFeedType.set(feedType);
	} catch (e) {
		console.error('Failed to load feed:', e);
	} finally {
		feedLoading.set(false);
	}
}

export async function loadMore() {
	let feedType: FeedType = 'for_you';
	currentFeedType.subscribe((v) => (feedType = v))();
	await loadFeed(feedType, false);
}

export async function createPost(content: string, sourceType: string) {
	try {
		await apiCreatePost(content, sourceType);
		// Reload current feed
		let feedType: FeedType = 'for_you';
		currentFeedType.subscribe((v) => (feedType = v))();
		await loadFeed(feedType);
	} catch (e) {
		console.error('Failed to create post:', e);
		throw e;
	}
}

export async function verifyPost(id: string) {
	await apiVerifyPost(id);
}

export async function flagPost(id: string) {
	await apiFlagPost(id);
}
