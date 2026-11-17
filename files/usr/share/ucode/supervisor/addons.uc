'use strict';
// Add-on management: catalog lookup, install/uninstall, lifecycle, per-add-on API tokens.
// Add-ons run as plain Docker containers (default bridge). They reach this supervisor at
// http://<bridge_ip>:<port> via SUPERVISOR_API (bashio honours it) and authenticate with a
// per-add-on SUPERVISOR_TOKEN that is only valid for /addons/self, /discovery, /services, /auth.
import * as docker from 'supervisor.docker';
import * as jobs from 'supervisor.jobs';
import * as http from 'supervisor.http';
import { load, STATE_DIR } from 'supervisor.config';
import { readfile, writefile, mkdir, popen } from 'fs';

const BASE = '/etc/ha-supervisor';
const STATE = BASE + '/addons.json';

export function catalog(cfg) {
	let c;
	try { c = json(readfile(cfg.catalog) ?? ''); } catch (e) { c = null; }
	return { addons: c?.addons ?? [], repositories: c?.repositories ?? [] };
};

export function find(cfg, slug) {
	for (let a in catalog(cfg).addons)
		if (a.slug == slug)
			return a;
	return null;
};

// Why an add-on cannot run here (the catalog lists runtime features this supervisor lacks).
export function unavailable_reason(a) {
	return 'This add-on needs features that ha-supervisor does not support: ' +
	       join(', ', a.unsupported ?? ['unknown']);
};

// DOCS.md / CHANGELOG.md of an add-on, fetched online from the repository the catalog was built
// from, at the pinned commit (the text is deliberately not shipped in the package). Tries
// raw.githubusercontent.com first; some networks only reach api.github.com, so it falls back to
// that one's contents API. Content at a pinned commit never changes: cached in tmpfs.
// Returns { text } or { error }.
export function doc(cfg, slug, kind) {
	let a = find(cfg, slug);
	let src = a?.source;
	if (!src)
		return { error: 'this add-on has no documentation source' };
	let file = kind == 'changelog' ? 'CHANGELOG.md' : 'DOCS.md';
	let cache = `${STATE_DIR}/docs/${slug}.${file}`;
	let cached = readfile(cache);
	if (cached != null)
		return { text: cached };
	let tries = [
		{ host: 'raw.githubusercontent.com', headers: {},
		  url: `https://raw.githubusercontent.com/${src.repo}/${src.ref}/${src.dir}/${file}` },
		{ host: 'api.github.com', headers: { Accept: 'application/vnd.github.raw' },
		  url: `https://api.github.com/repos/${src.repo}/contents/${src.dir}/${file}?ref=${src.ref}` }
	];
	for (let t in tries) {
		let r = http.request(t.url, { headers: t.headers, timeout: 15 });
		if (http.ok(r) && length(r.body)) {
			system(`mkdir -p '${STATE_DIR}/docs'`);
			writefile(cache, r.body);
			return { text: r.body };
		}
	}
	return { error: `Cannot download ${file} (tried raw.githubusercontent.com and api.github.com from ${src.repo}@${substr(src.ref, 0, 8)}): check the router's access to GitHub` };
};

function read_state() {
	let s;
	try { s = json(readfile(STATE) ?? ''); } catch (e) { s = null; }
	return s ?? { addons: {}, services: {} };
};

function write_state(st) {
	mkdir(BASE);
	writefile(STATE, sprintf('%J', st));
};

export function state() { return read_state(); };
export function cname(slug) { return 'addon_' + slug; };

// Slug of the add-on owning this token, or null.
export function by_token(tok) {
	if (!tok) return null;
	for (let slug, e in read_state().addons)
		if (e.token == tok)
			return slug;
	return null;
};

export function rand_hex(bytes) {
	let p = popen(`head -c ${bytes} /dev/urandom | hexdump -v -e '/1 "%02x"'`, 'r');
	let t = p ? trim(p.read('all')) : '';
	if (p) p.close();
	return length(t) == bytes * 2 ? t : null;
};

function new_token() { return rand_hex(24); };

function copy(v) { return json(sprintf('%J', v)); };

// --- container ------------------------------------------------------------------------

// One entry of an add-on's `map`: "name[:ro|:rw]" or {type, read_only}. Returns a Docker bind.
// Names follow the Supervisor: config/homeassistant_config = the Home Assistant config dir,
// app_config/addon_config = the add-on's private config, all_app_configs = every add-on's
// config, local_apps/addons = local add-ons; the rest (ssl, share, media, backup, ...) are
// plain directories under /etc/ha-supervisor.
function map_bind(cfg, slug, m) {
	let name, mode = 'ro';
	if (type(m) == 'object') {
		name = m.type;
		mode = m.read_only == false ? 'rw' : 'ro';
	} else {
		let p = split(`${m}`, ':');
		name = p[0];
		mode = p[1] ?? 'ro';
	}
	let host, dest = '/' + name;
	switch (name) {
	case 'config':
		host = cfg.config_dir; dest = '/config'; break;
	case 'homeassistant_config':
		host = cfg.config_dir; dest = '/homeassistant'; break;
	case 'addon_config':
	case 'app_config':
		host = `${BASE}/addons/${slug}/config`; dest = '/config'; break;
	case 'all_addon_configs':
	case 'all_app_configs':
		host = `${BASE}/addon_configs`; dest = '/addon_configs'; break;
	case 'addons':
	case 'local_apps':
		host = `${BASE}/local_addons`; dest = '/addons'; break;
	default:
		host = `${BASE}/${name}`;
	}
	system(`mkdir -p '${host}'`);
	return `${host}:${dest}:${mode}`;
};

function container_spec(cfg, slug, entry, spec) {
	let datadir = `${BASE}/addons/${slug}/data`;
	let binds = [`${datadir}:/data`];
	for (let m in spec.map ?? [])
		push(binds, map_bind(cfg, slug, m));
	let exposed = {}, bindings = {};
	for (let cport, hport in spec.ports ?? {}) {
		exposed[cport] = {};
		if (hport != null)
			bindings[cport] = [{ HostPort: `${hport}` }];
	}
	let api = `http://${cfg.bridge_ip}:${cfg.port}`;
	return {
		Image: `${entry.image}:${entry.version}`,
		Hostname: replace(slug, '_', '-'),
		Env: [`TZ=${cfg.timezone}`, `SUPERVISOR_TOKEN=${entry.token}`, `SUPERVISOR_API=${api}`],
		Labels: { 'ha.supervisor': 'addon', 'ha.addon': slug },
		ExposedPorts: exposed,
		HostConfig: {
			NetworkMode: 'bridge',
			// nginx-based add-ons resolve "supervisor" at start-up
			ExtraHosts: [`supervisor:${cfg.supervisor_ip}`],
			Binds: binds,
			PortBindings: bindings,
			RestartPolicy: { Name: entry.boot == 'manual' ? 'no' : 'unless-stopped' }
		}
	};
};

function write_options(slug, options) {
	let d = `${BASE}/addons/${slug}/data`;
	mkdir(BASE);
	mkdir(BASE + '/addons');
	mkdir(BASE + '/addons/' + slug);
	mkdir(d);
	writefile(d + '/options.json', sprintf('%J', options));
};

// --- lifecycle --------------------------------------------------------------------------

export function install(slug, job) {
	let cfg = load();
	function step(stage, pct) { if (job) jobs.update(job, { stage, progress: pct }); }
	function fail(msg) {
		if (job) jobs.update(job, { done: true, errors: [msg], stage: 'failed' });
		return { ok: false, error: msg };
	}

	let a = find(cfg, slug);
	if (!a) return fail('unknown add-on: ' + slug);
	let spec = a.spec ?? {};
	if (!(cfg.arch in (spec.arch ?? [])))
		return fail(`add-on does not support ${cfg.arch}`);
	if (a.available == false)
		return fail(unavailable_reason(a));
	let st = read_state();
	if (st.addons[slug]) return fail('already installed');
	if (docker.exists(cname(slug)) != false)
		return fail('container name in use or docker unavailable');
	let token = new_token();
	if (!token) return fail('cannot generate token');

	let image = replace(spec.image, '{arch}', cfg.arch);   // newer images are multi-arch: no {arch}
	let tag = a.version_latest;
	step('pulling', 10);
	let p = docker.pull(image, tag);
	if (!p.ok) return fail('pull failed: ' + p.error);

	step('creating', 70);
	let entry = { version: tag, token, boot: (spec.boot == 'manual' || spec.boot == 'manual_only') ? 'manual' : 'auto',
	              options: copy(spec.options ?? {}), image,
	              ingress_token: spec.ingress ? rand_hex(16) : null,
	              ingress_panel: false };      // "Show in sidebar" is off until the user turns it on
	write_options(slug, entry.options);
	let r = docker.create(cname(slug), container_spec(cfg, slug, entry, spec));
	if (!r.ok) return fail('create failed: ' + r.error);

	// register before start: the add-on calls our API right away
	st.addons[slug] = entry;
	write_state(st);

	step('starting', 90);
	if (!docker.start(cname(slug))) {
		docker.remove(cname(slug));
		delete st.addons[slug];
		write_state(st);
		return fail('start failed');
	}
	if (spec.ingress)
		system(`/usr/sbin/ha-supervisor panel-push ${slug} >/dev/null 2>&1 &`);
	if (job) jobs.update(job, { done: true, progress: 100, stage: 'done' });
	return { ok: true, version: tag };
};

export function uninstall(slug) {
	let st = read_state();
	if (!st.addons[slug]) return { ok: false, error: 'not installed' };
	docker.stop(cname(slug));
	docker.remove(cname(slug));
	delete st.addons[slug];
	write_state(st);
	system(`/usr/sbin/ha-supervisor panel-push ${slug} >/dev/null 2>&1 &`);   // data stays in /etc/ha-supervisor/addons/<slug>/data
	return { ok: true };
};

function installed_or_fail(slug) {
	return read_state().addons[slug];
};

export function start(slug)   { return installed_or_fail(slug) ? docker.start(cname(slug)) : false; };
export function stop(slug)    { return installed_or_fail(slug) ? docker.stop(cname(slug)) : false; };
export function restart(slug) { return installed_or_fail(slug) ? docker.restart(cname(slug)) : false; };
export function logs(slug, n) { return docker.logs(cname(slug), n ?? 200); };
export function stats(slug)   { return docker.stats(cname(slug)); };

export function set_options(slug, options) {
	let st = read_state();
	let e = st.addons[slug];
	if (!e) return false;
	e.options = options;
	write_state(st);
	write_options(slug, options);
	let i = docker.inspect(cname(slug));
	if (i?.State?.Running) docker.restart(cname(slug));
	return true;
};

// Add-on settings that are not its `options` (POST /addons/<slug>/options carries both).
// Keys the UI sets: boot, ingress_panel, auto_update, watchdog, network.
export function set_settings(slug, patch) {
	let st = read_state();
	let e = st.addons[slug];
	if (!e) return false;
	let panel_changed = patch.ingress_panel != null && !!patch.ingress_panel != !!e.ingress_panel;
	for (let k in ['boot', 'ingress_panel', 'auto_update', 'watchdog', 'network'])
		if (patch[k] != null)
			e[k] = patch[k];
	write_state(st);
	if (panel_changed)
		system(`/usr/sbin/ha-supervisor panel-push ${slug} >/dev/null 2>&1 &`);
	return true;
};

export function options(slug) { return read_state().addons[slug]?.options; };

// Token that identifies an add-on in /api/hassio_ingress/<token>/ (created on first use).
export function ingress_token(slug) {
	let st = read_state();
	let e = st.addons[slug];
	if (!e) return null;
	if (!e.ingress_token) {
		e.ingress_token = rand_hex(16);
		write_state(st);
	}
	return e.ingress_token;
};

// Ask HA to re-read /ingress/panels for this add-on (it registers or removes the sidebar panel).
export function panel_push(slug) {
	let cfg = load();
	let installed = !!read_state().addons[slug];
	let r = http.request(`http://localhost/api/hassio_push/panel/${slug}`,
		{ method: installed ? 'POST' : 'DELETE', unix: cfg.core_socket, timeout: 30 });
	return http.ok(r);
};

// --- API views --------------------------------------------------------------------------

function runtime_state(slug) {
	let i = docker.inspect(cname(slug));
	if (!i) return 'unknown';
	return i.State?.Running ? 'started' : 'stopped';
};

// InstalledAddon (also base of the complete view)
export function view(cfg, slug) {
	let a = find(cfg, slug);
	if (!a) return null;
	let e = read_state().addons[slug];
	let v = {};
	for (let k, x in a)
		if (k != 'spec')
			v[k] = x;
	v.installed = !!e;
	if (e) {
		v.version = e.version;
		v.state = runtime_state(slug);
		v.detached = false;
		v.update_available = false;
	}
	return v;
};

function schema_list(schema) {
	let out = [];
	for (let name, t in schema ?? {}) {
		let optional = false, ty = t;
		if (type(t) == 'string' && substr(t, -1) == '?') {
			optional = true;
			ty = substr(t, 0, -1);
		}
		let f = { name, required: !optional, optional };
		if (type(ty) == 'array') {
			f.type = 'schema';
			f.multiple = true;
			f.schema = schema_list(ty[0]);
		} else if (type(ty) == 'object') {
			f.type = 'schema';
			f.schema = schema_list(ty);
		} else if (ty == 'bool') f.type = 'boolean';
		else if (ty == 'int') f.type = 'integer';
		else if (ty == 'float') f.type = 'float';
		else if (ty == 'password') { f.type = 'string'; f.format = 'password'; }
		else f.type = 'string';
		push(out, f);
	}
	return out;
};

// InstalledAddonComplete / StoreAddonComplete (best effort, strict-model complete)
export function complete(cfg, slug) {
	let a = find(cfg, slug);
	if (!a) return null;
	let spec = a.spec ?? {};
	let v = view(cfg, slug);
	let e = read_state().addons[slug];
	v.apparmor = 'default';
	v.auth_api = !!spec.auth_api;
	v.docker_api = false;
	v.full_access = false;
	v.homeassistant_api = false;
	v.host_network = !!spec.host_network;
	v.host_pid = false;
	v.ingress = !!spec.ingress;
	v.long_description = null;
	v.rating = 5;
	v.signed = false;
	v.hassio_api = !!spec.hassio_api;
	v.hassio_role = spec.hassio_role ?? 'default';
	v.detached = false;      // part of the store model too (StoreAddonComplete)
	if (!e)
		return v;
	let i = docker.inspect(cname(slug));
	v.hostname = replace(slug, '_', '-');
	v.dns = [];
	v.protected = true;
	v.boot = e.boot;
	v.boot_config = 'auto';
	v.options = e.options;
	v.schema = schema_list(spec.schema);
	v.machine = [];
	v.network = {};
	for (let cport, hport in spec.ports ?? {})
		v.network[cport] = hport;
	v.network_description = {};
	v.host_ipc = false; v.host_uts = false; v.host_dbus = false;
	v.privileged = [];
	v.changelog = !!a.changelog; v.stdin = false; v.gpio = false; v.usb = false; v.uart = false;
	v.kernel_modules = false; v.devicetree = false; v.udev = false; v.video = false; v.audio = false;
	v.startup = spec.startup ?? 'application';
	v.services = spec.services ?? [];
	v.discovery = spec.discovery ?? [];
	v.translations = {};
	v.webui = spec.webui ?? null;
	if (spec.ingress) {
		let tok = ingress_token(slug);
		v.ingress_entry = `/api/hassio_ingress/${tok}`;
		v.ingress_url = `/api/hassio_ingress/${tok}/`;
		v.ingress_port = spec.ingress_port ?? 8099;
		v.ingress_panel = !!e.ingress_panel;
	} else {
		v.ingress_entry = null; v.ingress_url = null; v.ingress_port = null; v.ingress_panel = null;
	}
	v.audio_input = null; v.audio_output = null;
	v.auto_update = false;
	v.ip_address = i?.NetworkSettings?.IPAddress || '172.17.0.2';
	v.watchdog = false;
	v.devices = [];
	v.system_managed = false;
	v.system_managed_config_entry = null;
	v.log_format = 'journal';
	return v;
};

export function installed_list(cfg) {
	let out = [];
	for (let slug, e in read_state().addons) {
		let v = view(cfg, slug);
		if (v) push(out, v);
	}
	return out;
};

// --- services / discovery (stored as published by add-ons) ---------------------------------

// Add-ons advertise their container hostname, which only resolves on a Supervisor network.
// HA runs on the host network, so point it at the published port on localhost instead.
function fix_host(slug, config) {
	let c = copy(config ?? {});
	if (c.host == replace(slug, '_', '-'))
		c.host = '127.0.0.1';
	return c;
};

export function service_publish(name, slug, config) {
	config = fix_host(slug, config);
	let st = read_state();
	st.services ??= {};
	st.services[name] = { addon: slug, config };
	write_state(st);
};

export function service_get(name) { return read_state().services?.[name]; };

export function service_delete(name) {
	let st = read_state();
	if (st.services) delete st.services[name];
	write_state(st);
};

// discovery: stored so HA can list them at start-up and fetch one after a push
export function discovery_list() {
	let out = [];
	for (let u, d in read_state().discovery ?? {})
		push(out, d);
	return out;
};

export function discovery_get(uuid) { return read_state().discovery?.[uuid]; };

export function discovery_add(slug, service, config) {
	let st = read_state();
	st.discovery ??= {};
	let uuid;
	for (let u, d in st.discovery)       // same add-on+service updates the existing entry
		if (d.addon == slug && d.service == service)
			uuid = u;
	uuid ??= rand_hex(16);
	if (!uuid) return null;
	st.discovery[uuid] = { addon: slug, service, uuid, config: fix_host(slug, config) };
	write_state(st);
	return uuid;
};

export function discovery_delete(uuid) {
	let st = read_state();
	if (!st.discovery?.[uuid]) return false;
	delete st.discovery[uuid];
	write_state(st);
	return true;
};

// Tell HA there is something new; HA then fetches GET /discovery/<uuid> from us.
export function discovery_push(uuid) {
	let cfg = load();
	let r = http.request(`http://localhost/api/hassio_push/discovery/${uuid}`,
		{ method: 'POST', unix: cfg.core_socket, timeout: 60 });
	return http.ok(r);
};
