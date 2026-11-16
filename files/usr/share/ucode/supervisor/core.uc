'use strict';
// HA Core lifecycle: ensure running, info, update with rollback.
import * as docker from 'supervisor.docker';
import * as registry from 'supervisor.registry';
import * as jobs from 'supervisor.jobs';
import { load, STATE_DIR } from 'supervisor.config';
import { mkdir } from 'fs';

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

function backup_config(cfg, ver) {
	if (cfg.backup_before_update != '1') return true;
	mkdir(STATE_DIR);
	let f = `${cfg.config_dir}/../backup-${ver ?? 'x'}-${time()}.tar.gz`;
	return system(`tar -czf '${f}' -C '${cfg.config_dir}' . 2>/dev/null`) == 0;
};

// Install/update to `tag`. `job` is an optional job id for progress reporting.
export function update(tag, job) {
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
	let old_tag = running_tag(cfg);

	step('pulling', 10);
	let p = docker.pull(cfg.image, tag);
	if (!p.ok) return fail('pull failed: ' + p.error);

	step('backup', 50);
	backup_config(cfg, old_tag);

	step('switching', 60);
	let old = cfg.container + '_old';
	let had_old = !!old_tag;
	if (had_old) {
		docker.remove(old);
		docker.stop(cfg.container);
		docker.rename(cfg.container, old);
	}
	let r = run_tag(cfg, tag, token);
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
	let i = docker.inspect(cfg.container);
	if (!i) return update(null, null);
	if (!i.State?.Running) docker.start(cfg.container);
	return { ok: true };
};

export const start = () => docker.start(load().container);
export const stop = () => docker.stop(load().container);
export const restart = () => docker.restart(load().container);
export const logs = (n) => docker.logs(load().container, n);
export const stats = () => docker.stats(load().container);
