'use strict';
// Add-on management: catalog lookup, install/uninstall, lifecycle, per-add-on API tokens.
// Add-ons run as plain Docker containers (default bridge). They reach this supervisor at
// http://<bridge_ip>:<port> via SUPERVISOR_API (bashio honours it) and authenticate with a
// per-add-on SUPERVISOR_TOKEN that is only valid for /addons/self, /discovery, /services, /auth.
import * as docker from 'supervisor.docker';
import * as jobs from 'supervisor.jobs';
import { load } from 'supervisor.config';
import { readfile, writefile, mkdir, popen } from 'fs';

const BASE = '/etc/owrt-supervisor';
const STATE = BASE + '/addons.json';
const ARCH = 'armv7';

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

function new_token() {
	let p = popen("head -c 24 /dev/urandom | hexdump -v -e '/1 \"%02x\"'", 'r');
	let t = p ? trim(p.read('all')) : '';
	if (p) p.close();
	return length(t) == 48 ? t : null;
};

function copy(v) { return json(sprintf('%J', v)); };

// --- container ------------------------------------------------------------------------

function host_dir(cfg, slug, name) {
	if (name == 'config') return cfg.config_dir;
	let d = `${BASE}/${name}`;
	mkdir(BASE);
	mkdir(d);
	return d;
};

function container_spec(cfg, slug, entry, spec) {
	let datadir = `${BASE}/addons/${slug}/data`;
	let binds = [`${datadir}:/data`];
	for (let m in spec.map ?? []) {
		let p = split(`${m}`, ':');
		push(binds, `${host_dir(cfg, slug, p[0])}:/${p[0]}:${p[1] ?? 'ro'}`);
	}
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
		Labels: { 'owrt.supervisor': 'addon', 'owrt.addon': slug },
		ExposedPorts: exposed,
		HostConfig: {
			NetworkMode: 'bridge',
			// nginx-based add-ons resolve "supervisor" at start-up
			ExtraHosts: [`supervisor:${cfg.bridge_ip}`],
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
	if (!(ARCH in (spec.arch ?? [])))
		return fail(`add-on does not support ${ARCH}`);
	let st = read_state();
	if (st.addons[slug]) return fail('already installed');
	if (docker.exists(cname(slug)) != false)
		return fail('container name in use or docker unavailable');
	let token = new_token();
	if (!token) return fail('cannot generate token');

	let image = replace(spec.image, '{arch}', ARCH);
	let tag = a.version_latest;
	step('pulling', 10);
	let p = docker.pull(image, tag);
	if (!p.ok) return fail('pull failed: ' + p.error);

	step('creating', 70);
	let entry = { version: tag, token, boot: 'auto', options: copy(spec.options ?? {}), image };
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
	if (job) jobs.update(job, { done: true, progress: 100, stage: 'done' });
	return { ok: true, version: tag };
};

export function uninstall(slug) {
	let st = read_state();
	if (!st.addons[slug]) return { ok: false, error: 'not installed' };
	docker.stop(cname(slug));
	docker.remove(cname(slug));
	delete st.addons[slug];
	write_state(st);          // add-on data is kept in /etc/owrt-supervisor/addons/<slug>/data
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

export function options(slug) { return read_state().addons[slug]?.options; };

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
	v.ingress = false;
	v.long_description = null;
	v.rating = 5;
	v.signed = false;
	v.hassio_api = !!spec.hassio_api;
	v.hassio_role = spec.hassio_role ?? 'default';
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
	v.changelog = false; v.stdin = false; v.gpio = false; v.usb = false; v.uart = false;
	v.kernel_modules = false; v.devicetree = false; v.udev = false; v.video = false; v.audio = false;
	v.startup = spec.startup ?? 'application';
	v.services = spec.services ?? [];
	v.discovery = spec.discovery ?? [];
	v.translations = {};
	v.webui = spec.webui ?? null;
	v.ingress_entry = null; v.ingress_url = null; v.ingress_port = null; v.ingress_panel = null;
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

export function service_publish(name, slug, config) {
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
