import { writable } from 'svelte/store';
import { fetchFeed, createPost as apiCreatePost, verifyPost as apiVerify, flagPost as apiFlag } from '$lib/api';

export type FeedType = 'for_you' | 'following' | 'local' | 'crisis' | 'news';

export interface FeedPost {
	id: string;
	user_id: string;
	content: string;
	source_type: string;
	verification_score: number | null;
	created_at: string;
}

export const currentFeedType = writable<FeedType>('for_you');
export const feedPosts = writable<FeedPost[]>([]);
export const feedLoading = writable(false);
export const feedHasMore = writable(true);

let offset = 0;

export async function loadFeed(feedType: FeedType, reset = true) {
	feedLoading.set(true);
	if (reset) { offset = 0; feedPosts.set([]); }

	try {
		const response = (await fetchFeed(feedType, offset)) as { posts?: FeedPost[] };
		const posts = response?.posts ?? [];
		if (reset) { feedPosts.set(posts); } else { feedPosts.update(c => [...c, ...posts]); }
		feedHasMore.set(posts.length >= 20);
		offset += posts.length;
		currentFeedType.set(feedType);
	} catch (e) { console.error('Feed load failed:', e); }
	finally { feedLoading.set(false); }
}

export async function loadMore() {
	let ft: FeedType = 'for_you';
	currentFeedType.subscribe(v => ft = v)();
	await loadFeed(ft, false);
}

export async function createPost(content: string, sourceType: string) {
	await apiCreatePost(content, sourceType);
	let ft: FeedType = 'for_you';
	currentFeedType.subscribe(v => ft = v)();
	await loadFeed(ft);
}

export async function verifyPost(id: string) { await apiVerify(id); }
export async function flagPost(id: string) { await apiFlag(id); }
