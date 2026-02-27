<script lang="ts">
	import '../app.css';
	import { onMount } from 'svelte';
	import { isAuthenticated, initAuth } from '$lib/stores/auth';
	import { totalUnread } from '$lib/stores/messaging';
	import { page } from '$app/stores';
	import { goto } from '$app/navigation';

	let { children } = $props();
	let loading = $state(true);

	const navItems = [
		{ path: '/feed', label: 'Feed', icon: '📡' },
		{ path: '/messages', label: 'Messages', icon: '💬' },
		{ path: '/events', label: 'Events', icon: '📅' },
		{ path: '/alerts', label: 'Alerts', icon: '🚨' },
		{ path: '/settings', label: 'Settings', icon: '⚙️' }
	];

	onMount(async () => {
		const restored = await initAuth();
		loading = false;
		if (!restored) {
			goto('/');
		} else if ($page.url.pathname === '/') {
			goto('/feed');
		}
	});
</script>

{#if loading}
	<div class="loading-screen">
		<div class="loading-logo">K</div>
		<div class="loading-text">Kuurier</div>
	</div>
{:else if !$isAuthenticated}
	{@render children()}
{:else}
	<div class="app-layout">
		<nav class="sidebar">
			<div class="sidebar-header">
				<span class="logo">K</span>
				<span class="app-name">Kuurier</span>
			</div>
			<div class="nav-items">
				{#each navItems as item}
					<a href={item.path} class="nav-item" class:active={$page.url.pathname.startsWith(item.path)}>
						<span class="nav-icon">{item.icon}</span>
						<span class="nav-label">{item.label}</span>
						{#if item.path === '/messages' && $totalUnread > 0}
							<span class="badge">{$totalUnread}</span>
						{/if}
					</a>
				{/each}
			</div>
			<div class="sidebar-footer">
				<div class="connection-status warning">
					<span class="status-dot"></span>
					<span class="status-text">Web — use Tor Browser for IP privacy</span>
				</div>
			</div>
		</nav>
		<main class="content">{@render children()}</main>
	</div>
{/if}

<style>
	.loading-screen { display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100vh; gap: 12px; }
	.loading-logo { width: 64px; height: 64px; border-radius: 16px; background: var(--color-accent); color: var(--color-bg); display: flex; align-items: center; justify-content: center; font-size: 32px; font-weight: 700; }
	.loading-text { font-size: 18px; color: var(--color-text-secondary); }
	.app-layout { display: flex; height: 100vh; }
	.sidebar { width: var(--sidebar-width); background: var(--color-surface); border-right: 1px solid var(--color-border); display: flex; flex-direction: column; flex-shrink: 0; }
	.sidebar-header { padding: 16px; display: flex; align-items: center; gap: 10px; border-bottom: 1px solid var(--color-border); }
	.logo { width: 32px; height: 32px; border-radius: 8px; background: var(--color-accent); color: var(--color-bg); display: flex; align-items: center; justify-content: center; font-size: 18px; font-weight: 700; }
	.app-name { font-weight: 600; font-size: 16px; }
	.nav-items { flex: 1; padding: 8px; display: flex; flex-direction: column; gap: 2px; }
	.nav-item { display: flex; align-items: center; gap: 10px; padding: 10px 12px; border-radius: 8px; color: var(--color-text-secondary); text-decoration: none; transition: all 0.15s; }
	.nav-item:hover { background: var(--color-surface-hover); color: var(--color-text); text-decoration: none; }
	.nav-item.active { background: var(--color-surface-hover); color: var(--color-accent); }
	.nav-icon { font-size: 18px; width: 24px; text-align: center; }
	.nav-label { font-size: 14px; font-weight: 500; }
	.badge { margin-left: auto; background: var(--color-accent); color: var(--color-bg); font-size: 11px; font-weight: 600; padding: 2px 6px; border-radius: 9999px; }
	.sidebar-footer { padding: 12px 16px; border-top: 1px solid var(--color-border); }
	.connection-status { display: flex; align-items: center; gap: 8px; font-size: 11px; color: var(--color-text-secondary); }
	.connection-status.warning .status-dot { background: var(--color-warning); }
	.status-dot { width: 8px; height: 8px; border-radius: 50%; }
	.content { flex: 1; overflow: hidden; display: flex; flex-direction: column; }
</style>
