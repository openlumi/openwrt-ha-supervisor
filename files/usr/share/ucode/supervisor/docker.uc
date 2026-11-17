'use strict';
// Docker Engine API over /var/run/docker.sock
import * as http from 'supervisor.http';

const SOCK = '/var/run/docker.sock';
const API = 'http://localhost/v1.41';

function call(method, path, body, timeout) {
	return http.request(API + path, { method, unix: SOCK, body, timeout: timeout ?? 60 });
};

export function ping() {
	return http.ok(call('GET', '/_ping'));
};

export function inspect(name) {
	let r = call('GET', `/containers/${name}/json`);
	return http.ok(r) ? r.json : null;
};

// true / false, or null when docker could not answer (do NOT treat null as "missing").
export function exists(name) {
	let r = call('GET', `/containers/${name}/json`);
	if (http.ok(r)) return true;
	return r.status == 404 ? false : null;
};

export function image_exists(ref) {
	return http.ok(call('GET', `/images/${ref}/json`));
};

// Blocking pull; image + tag separately.
export function pull(image, tag) {
	let r = call('POST', `/images/create?fromImage=${image}&tag=${tag}`, null, 3600);
	// the stream is NDJSON; an "error" line means failure
	if (!http.ok(r) || index(r.body, '"error"') >= 0)
		return { ok: false, error: r.body };
	return { ok: true };
};

export function create(name, spec) {
	let r = call('POST', `/containers/create?name=${name}`, spec);
	return http.ok(r) ? { ok: true } : { ok: false, error: r.body };
};

export function start(name) {
	let r = call('POST', `/containers/${name}/start`);
	return r.status == 204 || r.status == 304;
};

export function stop(name, t) {
	let r = call('POST', `/containers/${name}/stop?t=${t ?? 30}`, null, (t ?? 30) + 30);
	return r.status == 204 || r.status == 304 || r.status == 404;
};

export function restart(name) {
	return call('POST', `/containers/${name}/restart?t=30`, null, 90).status == 204;
};

export function rename(name, newname) {
	return call('POST', `/containers/${name}/rename?name=${newname}`).status == 204;
};

export function remove(name) {
	let r = call('DELETE', `/containers/${name}?force=true`);
	return r.status == 204 || r.status == 404;
};

export function logs(name, tail) {
	// tty=true containers return raw text; otherwise multiplexed frames (best effort)
	return call('GET', `/containers/${name}/logs?stdout=1&stderr=1&tail=${tail ?? 200}`).body;
};

export function stats(name) {
	let r = call('GET', `/containers/${name}/stats?stream=false`);
	return http.ok(r) ? r.json : null;
};

export function health(name) {
	let i = inspect(name);
	return i?.State?.Health?.Status ?? (i?.State?.Running ? 'running' : 'stopped');
};

// Build a container spec matching the upstream docker-compose of HA-ARMv7.
export function core_spec(cfg, image_ref, sup_token) {
	let sockdir = replace(cfg.core_socket, /\/[^\/]*$/, '');
	let devs = map(cfg.devices, d => ({ PathOnHost: d, PathInContainer: d, CgroupPermissions: 'rwm' }));
	return {
		Image: image_ref,
		Env: [
			`TZ=${cfg.timezone}`,
			`SUPERVISOR=127.0.0.1:${cfg.port}`,
			`SUPERVISOR_TOKEN=${sup_token}`,
			// HA opens this unix socket and trusts it as the Supervisor user (discovery push)
			'SUPERVISOR_CORE_API_SOCKET=/run/supervisor-core/core.sock'
		],
		Labels: { 'ha.supervisor': 'core' },
		HostConfig: {
			NetworkMode: 'host',
			Privileged: true,
			RestartPolicy: { Name: 'unless-stopped' },
			Binds: [
				`${cfg.config_dir}:/config`,
				'/run/dbus:/run/dbus:ro',   // timezone comes from TZ (/etc/localtime is a symlink on OpenWrt)
				sockdir + ':/run/supervisor-core'
			],
			Devices: devs
		},
		Healthcheck: {
			// python3 exists in every HA image; curl is not guaranteed
			Test: ['CMD-SHELL', `python3 -c "import urllib.request; urllib.request.urlopen('${cfg.health_url}', timeout=8)" || exit 1`],
			Interval: 30000000000, Timeout: 10000000000, Retries: 5, StartPeriod: 120000000000
		}
	};
};
