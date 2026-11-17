'use strict';
// HA Core lifecycle: ensure running, info, update with rollback.
import * as docker from 'supervisor.docker';
import * as registry from 'supervisor.registry';
import * as jobs from 'supervisor.jobs';
import { load, STATE_DIR } from 'supervisor.config';
import { mkdir, writefile } from 'fs';

function image_ref(cfg, tag) { return `${cfg.image}:${tag}`; }

function running_tag(cfg) {
	let i = docker.inspect(cfg.container);
	if (!i) return null;
	let ref = i.Config?.Image ?? '';
	let p = rindex(ref, ':');
	return p > 0 ? substr(ref, p + 1) : 'latest';
};

export function info(cfg, force) {
	cfg ??= load();
	let i = docker.inspect(cfg.container);
	let ver = running_tag(cfg);
	let chk = registry.check(cfg, force);
	let latest = chk?.latest;
	return {
		version: ver,
		version_latest: latest,
		update_available: !!(ver && latest && latest != ver &&
			(latest == 'latest' ? false : registry.vcmp(ver, latest) < 0)),
		image: cfg.image,
		state: i?.State?.Status ?? 'missing',
		health: i ? docker.health(cfg.container) : null,
		boot: true
	};
};

// Create + start container for a tag (no pull).
function run_tag(cfg, tag, token) {
	let r = docker.create(cfg.container, docker.core_spec(cfg, image_ref(cfg, tag), token));
	if (!r.ok) return r;
	return docker.start(cfg.container) ? { ok: true } : { ok: false, error: 'start failed' };
};

function wait_healthy(cfg) {
	let end = time() + +cfg.health_timeout;
	while (time() < end) {
		let h = docker.health(cfg.container);
		if (h == 'healthy' || h == 'running') return true;
		if (h == 'stopped') return false;
		system('sleep 5');
	}
	return false;
};

// Config backup before an upgrade: tar of the HA config dir (without caches), kept outside
// /etc on the big volume; only the newest 3 are kept. Returns false on failure.
function backup_config(cfg, ver) {
	let dir = cfg.backup_dir;
	if (system(`mkdir -p '${dir}'`) != 0)
		return false;
	let f = `${dir}/backup-${ver ?? 'x'}-${time()}.tar.gz`;
	// busybox tar has no --exclude, only -X FILE
	let ex = STATE_DIR + '/backup.exclude';
	mkdir(STATE_DIR);
	writefile(ex, './.cache\n./deps\n');
	let rc = system(`tar -czf '${f}' -X '${ex}' -C '${cfg.config_dir}' . 2>/dev/null`);
	if (rc != 0) {
		system(`rm -f '${f}'`);
		return false;
	}
	system(`ls -1t '${dir}'/backup-*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm -f`);
	return true;
};

// Install/update to `tag`. `job` is an optional job id for progress reporting.
// `backup`: true/false from the caller (HA's "backup before update" checkbox), null = use policy.
export function update(tag, job, backup) {
	let cfg = load();
	let token = cfg.token;
	function step(stage, pct) { if (job) jobs.update(job, { stage, progress: pct }); }
	function fail(msg) {
		if (job) jobs.update(job, { done: true, errors: [msg], stage: 'failed' });
		return { ok: false, error: msg };
	}

	if (!docker.ping()) return fail('docker daemon not reachable');

	if (!tag) {
		let chk = registry.check(cfg, true);
		if (!chk?.latest) return fail('cannot determine latest version');
		tag = chk.latest;
	}
	// Never guess: if docker cannot tell us whether the container exists, stop here.
	let existing = docker.exists(cfg.container);
	if (existing == null) return fail('cannot query docker for the existing container');
	let old_tag = existing ? running_tag(cfg) : null;

	step('pulling', 10);
	let p = docker.pull(cfg.image, tag);
	if (!p.ok) return fail('pull failed: ' + p.error);

	// A backup only protects against irreversible migrations on a version change.
	let want_backup = backup ?? (cfg.backup_before_update == '1');
	if (want_backup && existing && old_tag != tag) {
		step('backup', 50);
		if (!backup_config(cfg, old_tag))
			return fail('backup failed, update aborted');
	}

	step('switching', 60);
	let old = cfg.container + '_old';
	let had_old = existing;
	if (had_old) {
		docker.remove(old);
		docker.stop(cfg.container);
		docker.rename(cfg.container, old);
	}
	mkdir(STATE_DIR);
	mkdir(replace(cfg.core_socket, /\/[^\/]*$/, ''));   // host side of HA's supervisor socket
	let created = false;
	let r = docker.create(cfg.container, docker.core_spec(cfg, image_ref(cfg, tag), token));
	if (r.ok) {
		created = true;
		r = docker.start(cfg.container) ? { ok: true } : { ok: false, error: 'start failed' };
	}
	if (r.ok) {
		step('health', 80);
		if (wait_healthy(cfg)) {
			if (had_old) docker.remove(old);
			if (job) jobs.update(job, { done: true, progress: 100, stage: 'done' });
			return { ok: true, version: tag };
		}
		r = { ok: false, error: 'new container not healthy' };
	}
	// rollback
	step('rollback', 90);
	if (created)                      // only remove what this run created
		docker.remove(cfg.container);
	if (had_old) {
		docker.rename(old, cfg.container);
		docker.start(cfg.container);
	}
	return fail(`${r.error}; rolled back to ${old_tag ?? 'nothing'}`);
};

// Make sure a container exists and runs (used at boot / first install).
export function ensure() {
	let cfg = load();
	// right after install/boot dockerd may still be starting: wait up to ~2 min
	for (let i = 0; i < 60 && !docker.ping(); i++)
		system('sleep 2');
	let ex = docker.exists(cfg.container);
	if (ex == null) return { ok: false, error: 'docker not ready' };
	if (!ex) return update(null, null);
	let i = docker.inspect(cfg.container);
	if (i && !i.State?.Running) docker.start(cfg.container);
	return { ok: true };
};

export const start = () => docker.start(load().container);
export const stop = () => docker.stop(load().container);
export const restart = () => docker.restart(load().container);
export const logs = (n) => docker.logs(load().container, n);
export const stats = () => docker.stats(load().container);
