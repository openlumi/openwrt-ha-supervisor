'use strict';
// Supervisor-compatible REST subset. handle(method, path, body) -> { code, body | text }
// Response shapes follow aiohasupervisor models (strict: every non-default field must be present).
import * as core from 'supervisor.core';
import * as jobs from 'supervisor.jobs';
import * as cfgm from 'supervisor.config';
import * as docker from 'supervisor.docker';
import { popen, readfile } from 'fs';
import { connect } from 'ubus';

const ARCH = 'armv7';
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

function channel(cfg) { return 'stable'; };

function root_info(cfg) {
	let b = board();
	return {
		supervisor: cfgm.VERSION, homeassistant: core.info(cfg).version, hassos: null, docker: 'ok',
		hostname: b.hostname, operating_system: os_name(), features: [],
		machine: b.model, machine_id: null, arch: ARCH, state: 'running', supported_arch: [ARCH],
		supported: true, channel: channel(cfg), logging: 'info', timezone: cfg.timezone
	};
};

function core_info(cfg) {
	let i = core.info(cfg);
	return {
		version: i.version, version_latest: i.version_latest, update_available: i.update_available,
		machine: board().model, ip_address: LOCAL_IP, arch: ARCH, image: cfg.image,
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
		channel: channel(cfg), arch: ARCH, supported: true, healthy: docker.ping(),
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

const STATIC = {
	'/store': { addons: [], repositories: [] },
	'/addons': { addons: [] },
	'/network/info': { interfaces: [],
	                   docker: { interface: 'docker0', address: '172.17.0.0/16', gateway: '172.17.0.1', dns: '172.17.0.1' },
	                   host_internet: true, supervisor_internet: true },
	'/mounts': { default_backup_mount: null, mounts: [] },
	'/resolution/info': { suggestions: [], unsupported: [], unhealthy: [], issues: [], checks: [] },
	'/jobs/info': { ignore_conditions: [], jobs: [] },
	'/available_updates': { available_updates: [] },
	'/discovery': { discovery: [], services: {} },
	'/ingress/panels': { panels: {} }
};

// POST endpoints that are accepted and ignored.
const NOOP_POST = ['/core/options', '/core/check', '/supervisor/reload', '/supervisor/repair',
                   '/supervisor/options', '/host/reload', '/store/reload', '/network/reload',
                   '/reload_updates', '/resolution/healthcheck', '/jobs/options', '/jobs/reset'];

export function handle(method, path, body) {
	let cfg = cfgm.load();
	path = replace(path, /\/+$/, '') || '/';

	switch (`${method} ${path}`) {
	case 'GET /supervisor/ping':    return ok();
	case 'GET /supervisor/info':    return ok(supervisor_info(cfg));
	case 'GET /supervisor/stats':   return ok(stats(null));
	case 'GET /info':               return ok(root_info(cfg));
	case 'GET /core/info':          return ok(core_info(cfg));
	case 'GET /core/stats':         return ok(stats(core.stats()));
	case 'GET /host/info':          return ok(host_info(cfg));
	case 'GET /os/info':            return ok(os_info());
	case 'POST /core/update': {
		let tag = body?.version;
		if (tag != null && !match(tag, /^[A-Za-z0-9._-]+$/))
			return err(400, 'invalid version');
		return ok({ job_id: jobs.spawn('update', tag ?? '') });
	}
	case 'POST /core/start':   return core.start() ? ok() : err(500, 'start failed');
	case 'POST /core/stop':    return core.stop() ? ok() : err(500, 'stop failed');
	case 'POST /core/restart': return core.restart() ? ok() : err(500, 'restart failed');
	case 'POST /core/rebuild': return ok({ job_id: jobs.spawn('update', core.info(cfg).version ?? '') });
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

	if (method == 'GET' && STATIC[path])
		return ok(STATIC[path]);
	if (method == 'POST' && (path in NOOP_POST))
		return ok();

	let m = match(path, /^\/jobs\/([a-z0-9-]+)$/);
	if (method == 'GET' && m) {
		let j = jobs.get(m[1]);
		return j ? ok(j) : err(404, 'unknown job');
	}
	return err(404, 'not supported');
};
