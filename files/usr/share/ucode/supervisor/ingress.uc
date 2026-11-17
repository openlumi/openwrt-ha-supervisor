'use strict';
// Add-on web UIs ("ingress"). Home Assistant's view /api/hassio_ingress/<token>/<path> has no auth
// of its own: it forwards the browser's request (cookies included) to
// http://<SUPERVISOR>/ingress/<token>/<path> and relies on us to check the session cookie.
//
//   sessions   POST /ingress/session, /ingress/validate_session (cookie ingress_session)
//   panels     GET /ingress/panels (the sidebar entries; "Show in sidebar" is per add-on)
//   proxy      request -> the add-on's container, WebSocket included
//
// The proxy is a raw relay (socat) so streaming and WebSocket just work. Official add-ons only
// accept requests from 172.30.32.2 (the real Supervisor's address): that address is put on `lo` and
// used as the source of the connection to the container.
import * as addons from 'supervisor.addons';
import * as docker from 'supervisor.docker';
import { STATE_DIR } from 'supervisor.config';
import { readfile, writefile, unlink, lsdir } from 'fs';

const SESSION_DIR = STATE_DIR + '/ingress';
const SESSION_TTL = 3600;          // sliding: every use renews it

export function session_create() {
	let id = addons.rand_hex(16);
	if (!id)
		return null;
	system(`mkdir -p '${SESSION_DIR}'`);
	let now = time();
	for (let f in lsdir(SESSION_DIR) ?? [])      // drop expired ones
		if (now - +(readfile(`${SESSION_DIR}/${f}`) ?? 0) > SESSION_TTL)
			unlink(`${SESSION_DIR}/${f}`);
	writefile(`${SESSION_DIR}/${id}`, `${now}`);
	return id;
};

export function session_valid(id) {
	if (!match(id ?? '', /^[0-9a-f]{32}$/))
		return false;
	let f = `${SESSION_DIR}/${id}`;
	let t = +(readfile(f) ?? 0);
	if (!t || time() - t > SESSION_TTL) {
		unlink(f);
		return false;
	}
	writefile(f, `${time()}`);
	return true;
};

// Sidebar panels: every installed add-on with a UI; `enable` is its "Show in sidebar" switch.
export function panels(cfg) {
	let out = {};
	for (let slug, e in addons.state().addons) {
		let a = addons.find(cfg, slug);
		let spec = a?.spec;
		if (!spec?.ingress)
			continue;
		out[slug] = {
			enable: !!e.ingress_panel,
			icon: spec.panel_icon ?? 'mdi:puzzle',
			title: spec.panel_title ?? a.name,
			admin: spec.panel_admin ?? true
		};
	}
	return out;
};

// token -> { slug, ip, port } of a running add-on, or null
export function target(cfg, token) {
	for (let slug, e in addons.state().addons) {
		if (e.ingress_token != token)
			continue;
		let spec = addons.find(cfg, slug)?.spec;
		if (!spec?.ingress)
			return null;
		let i = docker.inspect(addons.cname(slug));
		let ip = i?.NetworkSettings?.IPAddress;
		if (!i?.State?.Running || !ip)
			return null;
		return { slug, ip, port: spec.ingress_port ?? 8099 };
	}
	return null;
};

// Headers that must not reach the add-on: hop-by-hop ones, our own credentials, and the framing
// we recompute.
const DROP = {
	host: 1, connection: 1, 'keep-alive': 1, 'proxy-connection': 1, te: 1, trailer: 1,
	'transfer-encoding': 1, 'content-length': 1, authorization: 1, 'x-supervisor-token': 1, cookie: 1
};

// Session id from the Cookie header; the cookie header minus that cookie (the add-on does not
// need to see it).
export function cookie_session(headers) {
	let id, rest = [];
	for (let c in split(headers.cookie ?? '', ';')) {
		c = trim(c);
		let m = match(c, /^ingress_session=([0-9a-f]{32})$/);
		if (m)
			id = m[1];
		else if (length(c))
			push(rest, c);
	}
	return { id, rest: join('; ', rest) };
};

// Relay one request to the add-on and stream its answer to our stdout (the client socket).
// `target` from target(); `rest` is the request target after /ingress/<token> (path + query).
// Returns only if nothing could be relayed.
export function proxy(cfg, t, method, rest, headers, body, cookies) {
	let ws = lc(headers.upgrade ?? '') == 'websocket';
	let head = `${method} ${rest} HTTP/1.1\r\nHost: ${t.ip}:${t.port}\r\n`;
	for (let k, v in headers)
		if (!DROP[k] && !(ws == false && k == 'upgrade'))
			head += `${k}: ${v}\r\n`;
	if (length(cookies))
		head += `cookie: ${cookies}\r\n`;
	if (length(body))
		head += `content-length: ${length(body)}\r\n`;
	// one request per connection: the relay does not parse HTTP, so a reused connection would
	// carry the next request with an un-rewritten path
	head += ws ? 'connection: Upgrade\r\n' : 'connection: close\r\n';
	head += '\r\n';

	let f = `${STATE_DIR}/ingress.req.${time()}.${addons.rand_hex(4)}`;
	writefile(f, head + body);
	let peer = `TCP:${t.ip}:${t.port},bind=${cfg.supervisor_ip},shut-none`;
	// WebSocket: keep reading the client; plain request: the whole request is in the file
	let cmd = ws ? `cat '${f}' - | socat -t 3600 - ${peer}` : `cat '${f}' | socat -t 600 - ${peer}`;
	let rc = system(cmd);
	unlink(f);
	return rc;
};
