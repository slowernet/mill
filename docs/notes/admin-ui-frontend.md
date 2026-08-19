# Admin UI front end

How mill's web UI is built: stack, layout contract, design tokens, and the component catalog.
Adapted from a prior project's admin; routing, auth, and data access are covered in the
[design doc](../superpowers/specs/2026-08-06-software-factory-design.md#web-ui).

mill's UI is small and read-mostly. Four pages, four write actions, one live-updating view.
Everything else happens in GitHub.

## Contents

- [Stack](#stack)
- [Dependencies](#dependencies)
- [View conventions](#view-conventions)
- [Layout shell](#layout-shell)
- [Design tokens](#design-tokens)
- [CSS delivery](#css-delivery)
- [JavaScript foundation](#javascript-foundation)
- [Component catalog](#component-catalog)
  - [Button](#button)
  - [Card](#card)
  - [Badge](#badge)
  - [Table](#table)
  - [Stat tile](#stat-tile)
  - [Switch](#switch)
  - [Dialog](#dialog)
  - [Toast](#toast)
  - [Sidebar nav item](#sidebar-nav-item)
  - [Tabs](#tabs)
  - [Pagination](#pagination)
  - [Spinner](#spinner)
- [Write actions and CSRF](#write-actions-and-csrf)
- [The log tail](#the-log-tail)
- [Icons](#icons)
- [Asset cachebusting](#asset-cachebusting)
- [What mill uses where](#what-mill-uses-where)

## Stack

Server-rendered ERB. No build step, no bundler, no npm in the serving path, no framework
JavaScript. Every asset is a static file under `public/`.

The whole front end is:

- One layout file containing the shell, design tokens, and the CSS bootstrap script
- One page template per route, each wrapped in a `content_for` block
- One shared JS file (`public/js/utils.js`)
- Small inline `<script>` blocks in page templates for page-specific behavior

## Dependencies

Three external URLs, all CDN, all in `<head>`:

```erb
<script id="tailwind-play-cdn" data-src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"></script>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/basecoat-css@0.3.11/dist/basecoat.cdn.min.css">
<script src="https://cdn.jsdelivr.net/npm/basecoat-css@0.3.11/dist/js/all.min.js" defer></script>
```

**Tailwind CSS v4 browser build** compiles utility classes client-side. Note the `data-src`: the
script does not load unless the bootstrap decides it is needed (see [CSS delivery](#css-delivery)).

**[basecoat-css](https://basecoatui.com)** supplies shadcn-style component classes (`btn`, `card`,
`badge`, `tabs`, `input`) and a small JS bundle that listens for CustomEvents. No build step and
no framework dependency, which is why it fits.

Local scripts load `defer` with a cachebusting query string:

```erb
<script defer src="/js/utils.js?<%= ASSET_CACHEBUSTER %>"></script>
```

On a laptop mill binds `127.0.0.1:9494` and rejects requests whose `Host` is not `localhost:9494`
or `127.0.0.1:9494`. On a server both the bind and the `Host` allowlist are the deployment
hostname, and every route requires an allowlisted Google session — see the design doc's Web UI
section. The CDN dependencies are the only outbound requests the UI makes.

## View conventions

Every page template is entirely wrapped in `content_for` blocks. There is no bare markup at the
top level of any view:

```erb
<% content_for :head do %>
	<script>
		ready(() => { /* page-specific behavior */ })
	</script>
<% end %>

<% content_for :body do %>
	<div class="flex items-center justify-between mb-6">
		<h1 class="text-2xl font-semibold">Runs</h1>
	</div>
	...
<% end %>
```

The layout emits them in two places:

```erb
<%= content_for :head %>          <!-- inside <head> -->
<%= content_for :body %>          <!-- inside <main>, in a p-6 wrapper -->
```

This needs Roda's `content_for` plugin:

```ruby
plugin :render, views: 'app/views', layout: 'layout',
	allowed_paths: ['app/views', 'app/views/partials']
plugin :content_for
plugin :symbol_views
plugin :route_csrf
```

Two instance variables drive layout chrome, set by the route handler:

| Variable | Purpose |
|---|---|
| `@page_title` | Final breadcrumb segment, defaults to `Runs` |
| `@breadcrumb_parent` | Optional `{ url:, title: }` hash for an intermediate crumb |

mill has no scoping object — there is one factory, one board, one database. The scope selector
from the source project is dropped entirely.

## Layout shell

```erb
<body>
	<aside class="sidebar" data-side="left" aria-hidden="false">
		<nav aria-label="Main navigation" class="h-full">
			<section class="scrollbar flex flex-col justify-between h-full">
				<div><!-- nav group: Runs, Worktrees, Repos --></div>
				<div><!-- bottom nav group: health, pause switch --></div>
			</section>
		</nav>
	</aside>

	<main>
		<header class="sticky top-0 z-10 flex items-center gap-2 border-b bg-white px-4 lg:px-6" style="height: 61px;">
			<button type="button" class="p-1.5 hover:bg-gray-100 rounded" onclick="emit('basecoat:sidebar')">
				<!-- panel icon -->
			</button>
			<div class="w-px h-5 bg-border"></div>
			<nav aria-label="breadcrumb" class="h-9 flex items-center">
				<ol class="text-gray-600 flex flex-wrap items-center gap-1.5 text-sm">
					<!-- parent crumb, @page_title -->
				</ol>
			</nav>
		</header>

		<div class="w-full p-6">
			<%= content_for :body %>
		</div>

		<footer class="border-t bg-gray-50 px-6 py-6 text-xs text-gray-600 flex items-center justify-between">
			<span>disk: <%= @disk_used %></span>
			<button onclick="clearCssCache()" class="badge-secondary cursor-pointer opacity-60 hover:opacity-100">Clear CSS</button>
		</footer>
	</main>
</body>
```

`class="sidebar"` and the `basecoat:sidebar` event are basecoat's; responsive collapse comes free
with them. The header height is hardcoded at 61px inline to match the sidebar's own header band.

Breadcrumb assembly:

```erb
<% if @breadcrumb_parent %>
	<li class="inline-flex items-center gap-1.5">
		<a href="<%= @breadcrumb_parent[:url] %>" class="text-gray-900 font-normal hover:underline"><%= @breadcrumb_parent[:title] %></a>
	</li>
	<li aria-hidden="true"><!-- chevron --></li>
<% end %>
<li class="inline-flex items-center gap-1.5">
	<span class="text-gray-900 font-medium"><%= @page_title || 'Runs' %></span>
</li>
```

On a run detail page the route handler sets `@breadcrumb_parent = { url: '/', title: 'Runs' }`
and `@page_title = "##{run.subject_number}"`.

**Health banner.** When the poller or supervisor heartbeat goes stale, the layout renders a
banner above the body content. This is the one piece of chrome that is not navigation:

```erb
<% if @health_error %>
	<div class="bg-red-50 border-b border-red-200 px-6 py-3 text-sm text-red-800">
		<%= @health_error %>
	</div>
<% end %>
```

## Design tokens

Plain CSS custom properties in a `<style>` block in the layout. basecoat reads these, so
overriding them restyles every component at once.

```css
:root {
	--radius: 0.65rem;
	--background: #ffffff;
	--foreground: #0a0a0a;
	--card: #ffffff;
	--card-foreground: #0a0a0a;
	--popover: #ffffff;
	--popover-foreground: #0a0a0a;
	--primary: #171717;
	--primary-foreground: #fafafa;
	--secondary: #f5f5f5;
	--secondary-foreground: #171717;
	--muted: #f5f5f5;
	--muted-foreground: #737373;
	--accent: #f5f5f5;
	--accent-foreground: #171717;
	--destructive: #dc2626;
	--border: #e5e5e5;
	--input: #e5e5e5;
	--ring: #a3a3a3;
	--chart-1: #f97316;
	--chart-2: #06b6d4;
	--chart-3: #3b82f6;
	--chart-4: #eab308;
	--chart-5: #ef4444;
	--sidebar: #fafafa;
	--sidebar-foreground: #0a0a0a;
	--sidebar-primary: #171717;
	--sidebar-primary-foreground: #fafafa;
	--sidebar-accent: #e5e5e5;
	--sidebar-accent-foreground: #171717;
	--sidebar-border: #e5e5e5;
	--sidebar-ring: #a3a3a3;
}

.dark {
	/* full parallel set: #0a0a0a background, #fafafa foreground,
	   rgba(255,255,255,0.1) border, brighter chart colors */
}
```

Two local overrides sit alongside them:

```css
.card { padding-block: initial; gap: initial; }
input[type=checkbox][role=switch] { cursor: pointer; }
```

The `.dark` block is fully defined but nothing toggles the class. Dark mode is scaffolded, not
wired. To enable it, add a toggle that sets `document.documentElement.classList.toggle('dark')`
and persists to `localStorage`.

## CSS delivery

Tailwind's browser build recompiles every utility class on every page load, which is slow enough
to be visible. The layout works around it with a localStorage cache keyed by route shape.

A **synchronous** inline script runs first, before any render:

```js
// replace ids in path with ":id"
const css_key = ((p) => {
	return 'css:' + p.split('/').map(s => {
		if (!s) return s
		if (/(?=.*[a-zA-Z])(?=.*\d)/.test(s) || /^\d+$/.test(s)) return ':id'
		return s
	}).join('/')
})(window.location.pathname)

const clearCssCache = () => {
	Object.keys(localStorage).forEach(key => {
		if (key.startsWith('css:')) localStorage.removeItem(key)
	})
	console.log('css cache cleared')
	window.location.reload()
}

if (css = localStorage.getItem(css_key)) {
	const s = document.createElement('style')
	s.id = 'ls-css'
	s.textContent = css
	document.head.appendChild(s)
} else {
	window.__needsTailwindCdn = true

	// observe for insertion of the tailwind styles
	const headObserver = new MutationObserver((mutations) => {
		mutations.forEach((mutation) => {
			mutation.addedNodes.forEach((node) => {
				if (node.tagName === 'STYLE') {
					let timeout
					const styleObserver = new MutationObserver(() => {
						const content = node.textContent
						if (content.length > 0 && content.includes('tailwindcss')) {
							clearTimeout(timeout)
							timeout = setTimeout(() => {
								styleObserver.disconnect()
								localStorage.setItem(css_key, content)
							}, 100)
							headObserver.disconnect()
						}
					})
					styleObserver.observe(node, { characterData: true, childList: true, subtree: true })
				}
			})
		})
	})
	headObserver.observe(document.head, { childList: true })
}
```

Then a deferred module actually triggers the CDN download, only if needed:

```js
if (window.__needsTailwindCdn) {
	const s = qs('#tailwind-play-cdn')
	if (s) s.setAttribute('src', s.getAttribute('data-src'))
}
```

How it behaves:

1. Path segments that are all digits or mixed alphanumeric collapse to `:id`, so `/runs/12` and
   `/runs/847` share one cache entry. mill's run ids are integers, so this catches every detail
   page with one key.
2. On a cache hit the Tailwind CDN never loads at all.
3. On a miss, two nested MutationObservers wait for Tailwind's generated `<style>`, debounce
   100ms after its content settles, and store it.
4. The footer's "Clear CSS" button wipes every `css:` key and reloads.

mill has four route shapes (`/`, `/runs/:id`, `/worktrees`, `/repos`), so the cache holds at most
four entries and warms up within a few page loads. The cost is client-side compilation on a cold
cache and a cache a user can desync — the "Clear CSS" button is the escape hatch.

## JavaScript foundation

`public/js/utils.js` loads on every page and is the complete vocabulary:

```js
const qs = (s, o = document) => o.querySelector(s)

const qsa = (s, o = document) => o.querySelectorAll(s)

const ready = f => document.addEventListener('DOMContentLoaded', f)

const ael = (target, event, f) => target.addEventListener(event, f)

const on = (selector, event, handler, options) => {
	const el = typeof selector === 'string' ? qs(selector) : selector
	if (el) el.addEventListener(event, handler, options)
}

const onall = (selector, event, handler, options) => {
	(typeof selector === 'string' ? qsa(selector) : selector).forEach(el => el.addEventListener(event, handler, options))
}

const getjson = (url, options) => fetch(url, options).then(r => r.json())

const postjson = (url, data) => getjson(url, {
	method: 'POST',
	headers: {
		'Content-Type': 'application/json',
		'X-CSRF-Token': qs('meta[name="csrf-token"]').content
	},
	body: JSON.stringify(data)
})

const emit = (name, detail) => document.dispatchEvent(new CustomEvent(name, { detail }))

const toast = (category, title, description = '', duration = 3000) =>
	emit('basecoat:toast', { config: { category, title, description, duration }})

const escapeHtml = (text) => { const div = document.createElement('div'); div.textContent = text; return div.innerHTML }

const copyText = (text, el, msg = 'Copied!') => {
	navigator.clipboard.writeText(text)
	if (el) { el.classList.add('bg-green-100'); setTimeout(() => el.classList.remove('bg-green-100'), 500) }
	toast('success', msg)
}
```

The integration surface with basecoat is entirely CustomEvents — `emit('basecoat:sidebar')`
toggles the sidebar, `toast(...)` dispatches `basecoat:toast`. Nothing imports anything.

House JS rules that go with this: no semicolons (leading `;` for IIFEs), `const`/`let` only,
arrow functions, template literals for interpolation and single quotes otherwise, `async`/`await`
over `.then()` chains, all external JS deferred, all inline JS inside a `ready()` callback.

## Component catalog

Components are basecoat classes with Tailwind utilities layered on. There is no component
abstraction layer — markup is written out in each template.

### Button

```erb
<button class="btn">Default</button>
<button class="btn btn-primary">Primary</button>
<button class="btn btn-secondary">Secondary</button>
<button class="btn btn-outline text-gray-900">Outline</button>
<button class="btn btn-sm btn-secondary">Small</button>
<button class="btn btn-destructive">Kill run</button>
```

Anchors take the same classes. `btn-outline` is nearly always paired with `text-gray-900`, since
the token default is too light against white.

Icon buttons put a 16px inline SVG before the label; the `btn` class handles the gap.

### Card

The dominant page container. Header band, then body section:

```erb
<div class="card rounded-lg border shadow-sm">
	<header class="p-6 pb-4 border-b">
		<h2 class="text-lg font-semibold">Stage timeline</h2>
	</header>
	<section class="p-6">
		...
	</section>
</div>
```

Note the `.card { padding-block: initial; gap: initial }` override in the layout — basecoat's own
padding is stripped so the `p-6` utilities on `header` and `section` control spacing instead.

### Badge

Run and stage statuses map directly onto badge variants:

```erb
<span class="badge">running</span>
<span class="badge-outline">blocked</span>
<span class="badge-success">done</span>
<span class="badge-destructive">failed</span>
<span class="badge-destructive">killed</span>
```

Also used as a button skin, as in the footer's "Clear CSS".

### Table

Hand-rolled with Tailwind, not a basecoat class:

```erb
<table class="w-full">
	<thead class="border-b bg-gray-50">
		<tr>
			<th class="px-6 py-3 text-left text-xs font-medium text-gray-600 uppercase tracking-wider">Subject</th>
			<th class="px-6 py-3 text-left text-xs font-medium text-gray-600 uppercase tracking-wider">Route</th>
			<th class="px-6 py-3 text-left text-xs font-medium text-gray-600 uppercase tracking-wider">Stage</th>
			<th class="px-6 py-3 text-center text-xs font-medium text-gray-600 uppercase tracking-wider">Status</th>
			<th class="px-6 py-3 text-right text-xs font-medium text-gray-600 uppercase tracking-wider">Tokens</th>
		</tr>
	</thead>
	<tbody class="bg-white divide-y divide-gray-200">
		<% @runs.each do |run| %>
			<tr>
				<td class="px-6 py-4">
					<a href="/runs/<%= run.id %>" class="hover:underline"><%= run.repo.name %>#<%= run.subject_number %></a>
				</td>
				<td class="px-6 py-4 text-sm text-gray-600"><%= run.route %></td>
				<td class="px-6 py-4 text-sm"><%= run.current_stage %></td>
				<td class="px-6 py-4 text-center"><span class="badge-<%= badge_for(run.status) %>"><%= run.status %></span></td>
				<td class="px-6 py-4 text-right text-sm tabular-nums"><%= number_with_delimiter(run.tokens_total) %></td>
			</tr>
		<% end %>
	</tbody>
</table>
```

Wrap in a `card` for the border and shadow. `divide-y divide-gray-200` on `tbody` gives row
separators without per-row borders. Use `tabular-nums` on any numeric column so digits align.

### Stat tile

A grid of plain bordered boxes. No component class:

```erb
<div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6">
	<div class="bg-white rounded-lg border shadow-sm px-5 py-4">
		<div class="text-2xl font-semibold"><%= @stats[:running] %></div>
		<div class="text-xs text-gray-600">Running</div>
	</div>
	<div class="bg-white rounded-lg border shadow-sm px-5 py-4">
		<div class="text-2xl font-semibold text-amber-600"><%= @stats[:blocked] %></div>
		<div class="text-xs text-gray-600">Blocked</div>
	</div>
	<div class="bg-white rounded-lg border shadow-sm px-5 py-4">
		<div class="text-2xl font-semibold tabular-nums"><%= @stats[:tokens_today] %></div>
		<div class="text-xs text-gray-600">Tokens today</div>
	</div>
	<div class="bg-white rounded-lg border shadow-sm px-5 py-4">
		<div class="text-2xl font-semibold"><%= @stats[:disk] %></div>
		<div class="text-xs text-gray-600">Disk used</div>
	</div>
</div>
```

Semantic color goes on the number, never the tile.

### Switch

A checkbox with `role="switch"`; basecoat styles it. The layout adds `cursor: pointer`. mill uses
one, in the sidebar, to pause and resume claiming:

```erb
<div class="flex items-center justify-between px-3 py-2">
	<div>
		<label for="claiming" class="block text-sm font-medium">Claiming</label>
		<p class="text-xs text-gray-600">Start new runs</p>
	</div>
	<input type="checkbox" id="claiming" role="switch" class="input" <%= @paused ? '' : 'checked' %> />
</div>
```

```js
on('#claiming', 'change', async (e) => {
	const url = e.target.checked ? '/resume' : '/pause'
	const data = await postjson(url, {})
	data.success
		? toast('success', e.target.checked ? 'Claiming resumed' : 'Claiming paused')
		: toast('error', 'Failed', data.error)
})
```

### Dialog

Native `<dialog>`, opened with `showModal()` and closed with `close()`. No component library
involved. mill uses it to confirm destructive actions:

```erb
<dialog id="kill-dialog" class="rounded-lg shadow-xl backdrop:bg-black/50 p-0 w-full max-w-md mx-auto my-auto">
	<div class="flex flex-col">
		<div class="flex items-center justify-between px-6 py-4 border-b">
			<h2 class="text-lg font-semibold">Kill this run?</h2>
			<button type="button" id="kill-close-x" class="text-gray-400 hover:text-gray-600">
				<svg width="20" height="20"><!-- x icon --></svg>
			</button>
		</div>
		<div class="p-6">
			<p class="text-sm text-gray-600">
				mill sends SIGTERM to the process group, SIGKILL after a grace period, then confirms
				no descendant survives. The run is marked killed and its board Status set to Failed.
			</p>
		</div>
		<div class="flex justify-end gap-2 px-6 py-4 border-t bg-gray-50">
			<button type="button" class="btn btn-outline text-gray-900" onclick="qs('#kill-dialog').close()">Cancel</button>
			<button type="button" id="kill-confirm" class="btn btn-destructive">Kill</button>
		</div>
	</div>
</dialog>
```

`p-0` on the dialog with padding moved inside lets the header band run edge to edge.
`backdrop:bg-black/50` styles the native backdrop pseudo-element.

For an action that takes a moment, open the dialog immediately with a spinner, then fill it.
Close it and toast on failure.

### Toast

Fire and forget. No markup needed anywhere; basecoat's bundle owns the container.

```js
toast('success', 'Run killed')
toast('error', 'Kill failed', data.error || 'An error occurred')
toast('success', 'Copied')            // description and duration optional
```

Signature is `toast(category, title, description = '', duration = 3000)`.

### Sidebar nav item

Nav items are `<li><a>` with an inline icon and a span. Active state is a server-rendered class.

```erb
<div role="group" aria-labelledby="nav-main" class="px-3 py-3">
	<ul>
		<li>
			<a href="/" class="<%= request.path == '/' || request.path.start_with?('/runs') ? 'bg-sidebar-accent' : '' %>">
				<svg width="16" height="16"><!-- list icon --></svg>
				<span>Runs</span>
			</a>
		</li>
		<li>
			<a href="/worktrees" class="<%= request.path.start_with?('/worktrees') ? 'bg-sidebar-accent' : '' %>">
				<svg width="16" height="16"><!-- folder icon --></svg>
				<span>Worktrees</span>
			</a>
		</li>
		<li>
			<a href="/repos" class="<%= request.path.start_with?('/repos') ? 'bg-sidebar-accent' : '' %>">
				<svg width="16" height="16"><!-- git-branch icon --></svg>
				<span>Repos</span>
			</a>
		</li>
	</ul>
</div>
```

Active matching is a plain `request.path.start_with?` or `==` ternary. Detail routes match their
list route by prefix, so `/runs/12` highlights "Runs".

### Tabs

The run detail page splits into stages, verdicts, and log:

```erb
<div class="tabs w-full mb-4">
	<nav role="tablist" aria-orientation="horizontal" class="flex border-b">
		<% %w[stages verdicts log].each do |panel| %>
			<button
				role="tab"
				id="tab-<%= panel %>"
				aria-controls="panel-<%= panel %>"
				aria-selected="<%= panel == @selected_panel ? 'true' : 'false' %>"
				tabindex="<%= panel == @selected_panel ? '0' : '-1' %>"
				class="px-4 py-2 text-sm font-medium border-b-2 -mb-px <%= panel == @selected_panel ? 'border-primary text-primary' : 'border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300' %>"
			>
				<%= panel.capitalize %>
			</button>
		<% end %>
	</nav>
</div>
```

Panels are `<div role="tabpanel" id="panel-...">`. Active state is server-rendered; the `-mb-px`
pulls the active underline over the nav's bottom border. Roving `tabindex` keeps keyboard nav
correct.

### Pagination

A shared partial, `app/views/partials/_pagination.erb`, taking a `base_url` local:

```erb
<%# Required instance variables: @has_next, @has_prev, @next_offset, @prev_offset
    Required local: base_url %>
<% if @has_prev || @has_next %>
<nav class="flex items-center justify-end mt-6 gap-2" aria-label="Pagination">
	<% if @has_prev %>
		<a href="<%= ERB::Util.html_escape(base_url) %><%= base_url.include?('?') ? '&' : '?' %>offset=<%= @prev_offset %>"
		   class="btn btn-sm btn-outline text-gray-900">
			<svg width="16" height="16"><!-- chevron left --></svg>
			Prev
		</a>
	<% end %>
	<% if @has_next %>
		<a href="<%= ERB::Util.html_escape(base_url) %><%= base_url.include?('?') ? '&' : '?' %>offset=<%= @next_offset %>"
		   class="btn btn-sm btn-outline text-gray-900">
			Next
			<svg width="16" height="16"><!-- chevron right --></svg>
		</a>
	<% end %>
</nav>
<% end %>
```

Offset-based rather than cursor-based — mill's run table is small and lives in SQLite, so a count
query costs nothing. Keep the explicit `html_escape`.

### Spinner

Inline SVG with Tailwind's `animate-spin`, positioned absolutely inside a `relative` wrapper,
toggled by `hidden`:

```erb
<div class="relative">
	<div id="log-spinner" class="hidden absolute right-3 top-2.5">
		<svg class="animate-spin h-4 w-4 text-gray-400" viewBox="0 0 24 24" fill="none">
			<circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
			<path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
		</svg>
	</div>
</div>
```

## Write actions and CSRF

mill has four write endpoints: `POST /runs/:id/kill`, `POST /pause`, `POST /resume`, and
`POST /worktrees/:id/delete`. None of them is a form — each is a button that posts JSON and
toasts the result.

Roda's `route_csrf` plugin guards them. The layout puts the token in a meta tag:

```erb
<meta name="csrf-token" content="<%= csrf_token %>">
```

`postjson` reads it and sends it as `X-CSRF-Token` on every request, so page code never handles
the token directly.

The server contract both sides assume:

```json
{ "success": true }
{ "success": false, "error": "message" }
```

Sanitize secrets out of `error` before it reaches the browser — worktree paths and repo names are
fine, token values and env var contents are not.

Row-level actions post directly and update the DOM in place:

```js
onall('.worktree-delete', 'click', async (e) => {
	const row = e.target.closest('tr')
	const data = await postjson(`/worktrees/${row.dataset.id}/delete`, {})
	if (data.success) {
		row.remove()
		toast('success', 'Worktree deleted')
	} else {
		toast('error', 'Delete failed', data.error)
	}
})
```

## The log tail

The log tail is the only live-updating view in mill. Keep it dumb: poll a JSON endpoint, append
lines, stop when the attempt finishes. No client-side state machine, no reconnection logic, no
diffing.

**The tail belongs to one attempt.** Logs are written per launch —
`~/.mill/logs/<run-id>/<stage>-<number>.jsonl` — and a stage can be launched several times in
one run, so the run detail page links to each attempt rather than tailing "the run".

**The endpoint renders; this stays dumb.** What mill spawns emits `stream-json`, which is not
something a person reads. The endpoint flattens it to `{ at, kind, text }` — a tool call and its
result, a message, a rate-limit event, mill's own annotations — and the job here is appending and
escaping, exactly as below. Do not parse `stream-json` in the browser: the parser already exists on
the other side, and putting a second one here is how the two drift.

```js
ready(() => {
	const out = qs('#log-output')
	if (!out) return

	let offset = parseInt(out.dataset.offset || '0')
	const { runId, stage, attempt } = out.dataset

	const poll = async () => {
		const url = `/runs/${runId}/attempts/${stage}/${attempt}/log?offset=${offset}`
		const data = await getjson(url)
		if (data.lines.length) {
			out.insertAdjacentHTML('beforeend', data.lines.map(l =>
				`<div class="log-line log-line--${escapeHtml(l.kind)}">${escapeHtml(l.text)}</div>`).join(''))
			out.scrollTop = out.scrollHeight
			offset = data.offset
		}
		if (!data.finished) setTimeout(poll, 2000)
	}

	poll()
})
```

The endpoint returns `{ lines: [{ at, kind, text }], offset: <new offset>, finished: <bool> }`.
When `finished` is true the loop stops and the tail becomes a static transcript. `kind` is what the
line was — `tool`, `result`, `message`, `rate_limit`, `mill` — and drives styling only; nothing
branches on it. Both `kind` and `text` go through `escapeHtml`: log content is agent output and
must never be trusted as markup, and `kind` reaches a class attribute.

## Icons

Inline [Lucide](https://lucide.dev) SVGs pasted directly into markup. No sprite sheet, no icon
font.

```html
<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none"
     stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
	<path d="m15 18-6-6 6-6"/>
</svg>
```

Always 16px in nav, buttons and breadcrumbs; 20px for dialog close. `stroke="currentColor"` means
color is inherited from the parent, so no icon ever needs its own color class.

mill needs about eight icons total — list, folder, git-branch, panel, chevron left/right/down, x.
At that count a helper is not worth it; paste them. Revisit if the set grows past twenty.

## Asset cachebusting

```ruby
ASSET_CACHEBUSTER = `git rev-parse --short HEAD 2>/dev/null`.strip.freeze
```

Appended to every local asset URL as `?<%= ASSET_CACHEBUSTER %>`. mill runs from a git checkout
on your own machine, so shelling out at boot is fine — there is no deploy step that would need a
pre-written SHA file.

## What mill uses where

| Page | Components |
|---|---|
| `GET /` | Stat tile (running, blocked, tokens today, disk), Table (run list), Badge (status), Pagination |
| `GET /runs/:id` | Card (stage timeline, one row per attempt, linking to it), Table (per-stage token breakdown), Badge, Dialog (confirm kill), Spinner |
| `GET /runs/:id/attempts/:stage/:number` | Card (verdict first: status, artifact, questions or objections, cost), Badge, log tail underneath |
| `GET /worktrees` | Table (run, branch, status, disk), Button (delete per row), Dialog (confirm delete) |
| `GET /repos` | Card, Table (prepared state, resolved clone, prerequisites), Badge (healthy / unhealthy) |
| Layout | Sidebar nav item, Switch (pause claiming), Toast, health banner |

Dropped from the source project, because mill has no use for them: the scope selector (`select`
component), form fields and the `FormData` submission helper (mill has no forms), and dynamic
array fields with Rails-style bracket params (mill has no repeatable sub-records).
