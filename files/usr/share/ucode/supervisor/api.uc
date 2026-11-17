'use strict';
// Supervisor-compatible REST subset. handle(method, path, body) -> { code, body | text }
// Response shapes follow aiohasupervisor models (strict: every non-default field must be present).
import * as core from 'supervisor.core';
import * as jobs from 'supervisor.jobs';
import * as cfgm from 'supervisor.config';
import * as docker from 'supervisor.docker';
import * as addons from 'supervisor.addons';
import { popen, readfile, lsdir, readlink } from 'fs';
import { rand } from 'math';
import { connect } from 'ubus';

const LOCAL_IP = '127.0.0.1';

function ok(data) { return { code: 200, body: { result: 'ok', data: data ?? {} } }; };
function err(code, msg) { return { code, body: { result: 'error', message: msg } }; };

function board() {
	let u = connect();
	return (u ? u.call('system', 'board') : null) ?? {};
};

// OPENWRT_RELEASE from /etc/os-release, falling back to ubus board description.
function os_name() {
	for (let l in split(readfile('/etc/os-release') ?? '', '\n')) {
		let m = match(l, /^OPENWRT_RELEASE="?([^"]*)"?$/);
		if (m) return m[1];
	}
	return board().release?.description;
};

// [total, used, free] in GB for the filesystem holding `path`.
function disk(path) {
	let p = popen(`df -k ${path} 2>/dev/null | tail -n 1`, 'r');
	let line = p ? p.read('all') : '';
	if (p) p.close();
	let f = split(trim(line), /\s+/);
	let gb = (k) => +k / 1024 / 1024;
	return length(f) >= 4 ? [gb(f[1]), gb(f[2]), gb(f[3])] : [0, 0, 0];
};

// Supervisor DiskUsage tree (storage page). Depth is fixed at one level.
function sh_kb(cmd) {
	let p = popen(cmd, 'r');
	let out = p ? p.read('all') : '';
	if (p) p.close();
	return +split(trim(out), /\s+/)[0] || 0;
};

function disk_usage(cfg) {
	let d = split(trim((() => { let p = popen('df -k / 2>/dev/null | tail -n 1', 'r'); let o = p ? p.read('all') : ''; if (p) p.close(); return o; })()), /\s+/);
	let total = (+d[1] || 0) * 1024, used = (+d[2] || 0) * 1024;
	let ha = sh_kb(`du -sk '${cfg.config_dir}' 2>/dev/null`) * 1024;
	return { id: 'root', label: 'Total', used_bytes: used, total_bytes: total, children: [
		{ id: 'homeassistant', label: 'Home Assistant', used_bytes: ha },
		{ id: 'system', label: 'System', used_bytes: used > ha ? used - ha : 0 }
	] };
};

function catalog(cfg) { return addons.catalog(cfg); };

function channel(cfg) { return 'stable'; };

function root_info(cfg) {
	let b = board();
	return {
		supervisor: cfgm.VERSION, homeassistant: core.info(cfg).version, hassos: null, docker: 'ok',
		hostname: b.hostname, operating_system: os_name(), features: [],
		machine: b.model, machine_id: null, arch: cfg.arch, state: 'running', supported_arch: [cfg.arch],
		supported: true, channel: channel(cfg), logging: 'info', timezone: cfg.timezone
	};
};

function core_info(cfg) {
	let i = core.info(cfg);
	return {
		version: i.version, version_latest: i.version_latest, update_available: i.update_available,
		machine: board().model, ip_address: LOCAL_IP, arch: cfg.arch, image: cfg.image,
		boot: true, port: 8123, ssl: false, watchdog: true, audio_input: null, audio_output: null,
		backups_exclude_database: false, duplicate_log_file: false,
		// extras (ignored by the client if unknown)
		state: i.state, health: i.health
	};
};

function stats(s) {
	let r = { cpu_percent: 0.0, memory_usage: 0, memory_limit: 0, memory_percent: 0.0,
	          network_rx: 0, network_tx: 0, blk_read: 0, blk_write: 0 };
	if (!s) return r;
	let mem = s.memory_stats?.usage ?? 0, lim = s.memory_stats?.limit ?? 0;
	r.memory_usage = mem;
	r.memory_limit = lim;
	r.memory_percent = lim ? mem * 100.0 / lim : 0.0;
	let cd = (s.cpu_stats?.cpu_usage?.total_usage ?? 0) - (s.precpu_stats?.cpu_usage?.total_usage ?? 0);
	let sd = (s.cpu_stats?.system_cpu_usage ?? 0) - (s.precpu_stats?.system_cpu_usage ?? 0);
	if (cd > 0 && sd > 0)
		r.cpu_percent = cd * 100.0 / sd * (s.cpu_stats?.online_cpus ?? 1);
	for (let k, n in s.networks ?? {}) {
		r.network_rx += n.rx_bytes ?? 0;
		r.network_tx += n.tx_bytes ?? 0;
	}
	return r;
};

function supervisor_info(cfg) {
	return {
		version: cfgm.VERSION, version_latest: cfgm.VERSION, update_available: false,
		channel: channel(cfg), arch: cfg.arch, supported: true, healthy: docker.ping(),
		ip_address: LOCAL_IP, timezone: cfg.timezone, logging: 'info', debug: false, debug_block: false,
		diagnostics: false, auto_update: false, country: null, detect_blocking_io: false,
		feature_flags: {}
	};
};

function host_info(cfg) {
	let b = board(), d = disk('/');
	return {
		agent_version: null, apparmor_version: null, chassis: 'embedded', virtualization: null,
		cpe: null, deployment: 'production', disk_free: d[2], disk_total: d[0], disk_used: d[1],
		disk_life_time: null, features: ['reboot', 'shutdown'], hostname: b.hostname, llmnr_hostname: null,
		kernel: b.kernel, operating_system: os_name(), timezone: cfg.timezone,
		dt_utc: null, dt_synchronized: null, use_ntp: null, startup_time: null, boot_timestamp: null,
		broadcast_llmnr: null, broadcast_mdns: null
	};
};

function os_info() {
	let v = os_name();
	return { version: v, version_latest: v, version_pending: null, update_available: false,
	         board: null, boot: null, data_disk: null, boot_slots: {} };
};

// Real serial ports (USB sticks and on-SoC UARTs such as ttymxc*) in the Supervisor
// hardware/info shape. Built from sysfs so phantom 8250 nodes and ptys are skipped,
// and the kernel console (it is in use by the system) is left out.
function hardware_info() {
	let by_id = {};
	for (let n in lsdir('/dev/serial/by-id') ?? []) {
		let t = readlink('/dev/serial/by-id/' + n);
		if (t) by_id[replace(t, /^.*\//, '')] = '/dev/serial/by-id/' + n;
	}
	let consoles = {};
	for (let l in split(readfile('/proc/consoles') ?? '', '\n')) {
		let m = match(l, /^(\S+)/);
		if (m) consoles[m[1]] = true;
	}
	let devnodes = lsdir('/dev') ?? [];
	let devices = [];
	for (let n in sort(lsdir('/sys/class/tty') ?? [])) {
		let base = '/sys/class/tty/' + n;
		if (!readlink(base + '/device') || consoles[n])
			continue;
		let type = readfile(base + '/type');
		if (type != null && trim(type) == '0')   // unconfigured 8250 slot
			continue;
		if (!(n in devnodes))
			continue;
		let t = readlink(base) ?? '';
		push(devices, { name: n, sysfs: '/sys/' + replace(t, /^(\.\.\/)+/, ''), dev_path: '/dev/' + n,
		                subsystem: 'tty', parent: null, by_id: by_id[n], attributes: {}, children: [] });
	}
	return { devices };
};

// System log as plain text. Supervisor clients ask for N lines via `Range: entries=:-N:`.
function host_logs(headers) {
	let n = 100;
	let m = match(headers?.range ?? '', /^entries=[^:]*:-?([0-9]+):/);
	if (m) n = min(+m[1] || 100, 5000);
	let p = popen(`logread -l ${n} 2>&1`, 'r');
	let out = p ? p.read('all') : '';
	if (p) p.close();
	return out;
};

const STATIC = {
	'/network/info': { interfaces: [],
	                   docker: { interface: 'docker0', address: '172.17.0.0/16', gateway: '172.17.0.1', dns: '172.17.0.1' },
	                   host_internet: true, supervisor_internet: true },
	'/mounts': { default_backup_mount: null, mounts: [] },
	'/resolution/info': { suggestions: [], unsupported: [], unhealthy: [], issues: [], checks: [] },
	'/jobs/info': { ignore_conditions: [], jobs: [] },
	'/available_updates': { available_updates: [] },
	'/backups': { backups: [] },
	'/backups/info': { backups: [], days_until_stale: 30 },
	'/ingress/panels': { panels: {} }
};

// POST endpoints that are accepted and ignored.
const NOOP_POST = ['/core/options', '/core/check', '/supervisor/reload', '/supervisor/repair',
                   '/supervisor/options', '/host/reload', '/store/reload', '/network/reload',
                   '/reload_updates', '/resolution/healthcheck', '/backups/options', '/backups/reload', '/backups/freeze', '/backups/thaw', '/jobs/options', '/jobs/reset'];

// Add-on tokens may only use their own /addons/self subtree plus discovery/services/auth.
function allowed_for_addon(path, slug) {
	let own = '/addons/' + slug;
	return path == own || index(path, own + '/') == 0 ||
	       match(path, /^\/(discovery|services|auth)(\/|$)/) || path == '/supervisor/ping' || path == '/info';
};

export function handle(method, path, body, headers, principal) {
	let cfg = cfgm.load();
	path = replace(path, /\/+$/, '') || '/';
	principal ??= 'supervisor';
	if (principal != 'supervisor') {
		if (path == '/addons/self' || index(path, '/addons/self/') == 0)
			path = '/addons/' + principal + substr(path, length('/addons/self'));
		if (!allowed_for_addon(path, principal))
			return err(403, 'forbidden for add-on tokens');
	}

	switch (`${method} ${path}`) {
	case 'GET /supervisor/ping':    return ok();
	case 'GET /supervisor/info':    return ok(supervisor_info(cfg));
	case 'GET /supervisor/stats':   return ok(stats(null));
	case 'GET /info':               return ok(root_info(cfg));
	case 'GET /core/info':          return ok(core_info(cfg));
	case 'GET /core/stats':         return ok(stats(core.stats()));
	case 'GET /host/info':          return ok(host_info(cfg));
	case 'GET /os/info':            return ok(os_info());
	case 'GET /store':              return ok(catalog(cfg));
	case 'GET /store/addons':       return ok({ addons: catalog(cfg).addons });
	case 'GET /store/repositories': return ok(catalog(cfg).repositories);
	case 'GET /hardware/info':      return ok(hardware_info());
	case 'GET /host/disks/default/usage': return ok(disk_usage(cfg));
	case 'POST /core/update': {
		let tag = body?.version;
		if (tag != null && !match(tag, /^[A-Za-z0-9._-]+$/))
			return err(400, 'invalid version');
		// HA's "backup before update" checkbox sends backup=true; absent/false means no backup
		let flag = body?.backup ? '--backup' : '--no-backup';
		return ok({ job_id: jobs.spawn('update', `${tag ?? ''} ${flag}`) });
	}
	case 'POST /core/start':   return core.start() ? ok() : err(500, 'start failed');
	case 'POST /core/stop':    return core.stop() ? ok() : err(500, 'stop failed');
	case 'POST /core/restart': return core.restart() ? ok() : err(500, 'restart failed');
	case 'POST /core/rebuild': return ok({ job_id: jobs.spawn('update', `${core.info(cfg).version ?? ''} --no-backup`) });
	case 'GET /core/logs':     return { code: 200, text: core.logs(200) };
	case 'POST /refresh_updates':
		core.info(cfg, true);
		return ok();
	case 'GET /supervisor/options':
		return ok({ image: cfg.image, channel: cfg.channel });
	case 'POST /supervisor/options':
		for (let k in ['image', 'channel']) {
			if (body?.[k] == null) continue;
			if (!match(body[k], /^[A-Za-z0-9._\/:-]+$/))
				return err(400, `invalid ${k}`);
			cfgm.set(k, body[k]);
		}
		return ok();
	case 'POST /host/reboot':
		system('(sleep 2; reboot) >/dev/null 2>&1 &');
		return ok();
	case 'POST /host/shutdown':
		system('(sleep 2; poweroff) >/dev/null 2>&1 &');
		return ok();
	}

	if (method == 'GET' && path == '/host/logs/boots')
		return ok({ boots: { '0': 'current' } });
	if (method == 'GET' && path == '/host/logs/identifiers')
		return ok({ identifiers: [] });
	if (method == 'GET' && match(path, /^\/host\/logs(\/(boots\/[^\/]+|latest|identifiers\/[^\/]+))*(\/follow)?$/))
		return { code: 200, text: host_logs(headers) };
	if (method == 'GET' && STATIC[path])
		return ok(STATIC[path]);
	if (method == 'POST' && (path in NOOP_POST))
		return ok();

	// --- add-ons -------------------------------------------------------------------------
	if (method == 'GET' && path == '/addons')
		return ok({ addons: addons.installed_list(cfg) });

	let am = match(path, /^\/addons\/([A-Za-z0-9_]+)(\/.*)?$/);
	if (am) {
		let slug = am[1], sub = am[2] ?? '/info';
		if (slug == 'self')
			return err(404, 'no add-on context');
		if (!addons.state().addons[slug])
			return err(404, `Add-on ${slug} is not installed`);
		switch (`${method} ${sub}`) {
		case 'GET /info':           return ok(addons.complete(cfg, slug));
		case 'POST /start':         return addons.start(slug) ? ok() : err(500, 'start failed');
		case 'POST /stop':          return addons.stop(slug) ? ok() : err(500, 'stop failed');
		case 'POST /restart':       return addons.restart(slug) ? ok() : err(500, 'restart failed');
		case 'POST /uninstall': {
			let r = addons.uninstall(slug);
			return r.ok ? ok() : err(500, r.error);
		}
		case 'GET /options/config': return ok(addons.options(slug) ?? {});
		case 'POST /options':
			if (type(body?.options) != 'object')
				return err(400, 'options object required');
			return addons.set_options(slug, body.options) ? ok() : err(500, 'cannot set options');
		case 'GET /logs':           return { code: 200, text: addons.logs(slug, 200) };
		case 'GET /stats':          return ok(stats(addons.stats(slug)));
		}
		return err(404, 'not supported');
	}

	let sm = match(path, /^\/store\/addons\/([A-Za-z0-9_]+)(\/(install|update|availability))?$/);
	if (sm) {
		let slug = sm[1], act = sm[3];
		if (!addons.find(cfg, slug))
			return err(404, `Add-on ${slug} does not exist`);
		if (!act && method == 'GET')
			return ok(addons.complete(cfg, slug));
		if (act == 'availability' && method == 'GET') {
			let a = addons.find(cfg, slug);
			return a.available == false ? err(400, addons.unavailable_reason(a)) : ok();
		}
		if (act == 'update')
			return err(400, 'The add-on catalog is a frozen snapshot: updates are not available');
		if (act == 'install' && method == 'POST') {
			let id = jobs.spawn('addon-install', slug);
			if (body?.background)
				return ok({ job_id: id });
			for (let i = 0; i < 1800; i++) {      // up to ~1 h, like a blocking Supervisor call
				let j = jobs.get(id);
				if (j?.done)
					return length(j.errors ?? []) ? err(500, j.errors[0]) : ok({ job_id: id });
				system('sleep 2');
			}
			return err(504, 'install timed out');
		}
	}

	// --- services / discovery / auth (called by add-ons) -----------------------------------
	if (path == '/services/mqtt') {
		if (method == 'POST' && principal != 'supervisor' && type(body) == 'object') {
			addons.service_publish('mqtt', principal, body);
			return ok();
		}
		if (method == 'DELETE') { addons.service_delete('mqtt'); return ok(); }
		if (method == 'GET') {
			let sv = addons.service_get('mqtt');
			if (!sv) return err(400, 'no MQTT service available');
			let d = { addon: sv.addon };
			for (let k, v in sv.config) d[k] = v;
			return ok(d);
		}
	}
	if (path == '/discovery' && method == 'GET')
		return ok({ discovery: addons.discovery_list() });
	if (path == '/discovery' && method == 'POST') {
		if (principal == 'supervisor' || type(body?.config) != 'object' || type(body?.service) != 'string')
			return err(400, 'service and config required, from an add-on');
		let uuid = addons.discovery_add(principal, body.service, body.config);
		if (!uuid) return err(500, 'cannot store discovery');
		// push to HA in the background (retries while HA is starting)
		system(`/usr/sbin/ha-supervisor discovery-push ${uuid} >/dev/null 2>&1 &`);
		return ok({ uuid });
	}
	let dm = match(path, /^\/discovery\/([a-f0-9]{32})$/);
	if (dm && method == 'GET') {
		let d = addons.discovery_get(dm[1]);
		return d ? ok(d) : err(404, 'unknown discovery');
	}
	if (dm && method == 'DELETE')
		return addons.discovery_delete(dm[1]) ? ok() : err(404, 'unknown discovery');
	if (method == 'POST' && path == '/auth')
		return err(401, 'Unauthorized');

	let m = match(path, /^\/jobs\/([a-z0-9-]+)$/);
	if (method == 'GET' && m) {
		let j = jobs.get(m[1]);
		return j ? ok(j) : err(404, 'unknown job');
	}
	return err(404, 'not supported');
};
