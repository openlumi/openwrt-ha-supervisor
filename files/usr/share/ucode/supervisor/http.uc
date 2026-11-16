'use strict';
// Tiny HTTP helper with no extra packages:
//  - Unix socket (Docker): raw HTTP/1.0 through socat (HTTP/1.0 => no chunked replies)
//  - TCP/HTTPS (registry): uclient-fetch (wget)
import { popen, writefile, unlink, mkdir } from 'fs';
import { rand } from 'math';

function shq(s) {
	return "'" + replace(`${s}`, "'", "'\\''") + "'";
};

function tmpname() {
	mkdir('/var/run/owrt-supervisor');
	return `/var/run/owrt-supervisor/req.${time()}.${rand()}`;
};

function run(cmd) {
	let p = popen(cmd, 'r');
	if (!p)
		return null;
	let out = p.read('all');
	p.close();
	return out;
};

function parse_json(body) {
	try { return json(body); } catch (e) { return null; }
};

// opts: { method, headers: {k: v}, body, unix, user, timeout }
// returns { status, body, json }
function unix_request(url, opts) {
	let path = replace(url, /^https?:\/\/[^\/]*/, '');
	let body = opts.body == null ? '' : (type(opts.body) == 'string' ? opts.body : sprintf('%J', opts.body));
	let req = `${opts.method ?? 'GET'} ${path} HTTP/1.0\r\nHost: localhost\r\n`;
	if (opts.body != null)
		req += `Content-Type: application/json\r\nContent-Length: ${length(body)}\r\n`;
	for (let k, v in opts.headers ?? {})
		req += `${k}: ${v}\r\n`;
	req += '\r\n' + body;

	let f = tmpname();
	writefile(f, req);
	let out = run(`socat -t${opts.timeout ?? 60} - UNIX-CONNECT:${shq(opts.unix)},shut-none <${f} 2>/dev/null`);
	unlink(f);
	if (!out)
		return { status: 0, body: 'no response' };

	let sep = index(out, '\r\n\r\n');
	let head = sep >= 0 ? substr(out, 0, sep) : out;
	let rbody = sep >= 0 ? substr(out, sep + 4) : '';
	let m = match(head, /^HTTP\/[0-9.]+ ([0-9]+)/);
	return { status: m ? +m[1] : 0, body: rbody, json: parse_json(rbody) };
};

function wget_request(url, opts) {
	let cmd = ['wget', '-q', '-O', '-', `--timeout=${opts.timeout ?? 60}`];
	if (opts.user) {
		let up = split(opts.user, ':', 2);
		push(cmd, '--user=' + shq(up[0]), '--password=' + shq(up[1] ?? ''));
	}
	for (let k, v in opts.headers ?? {})
		push(cmd, '--header=' + shq(`${k}: ${v}`));
	let tmp;
	if (opts.method && opts.method != 'GET') {
		push(cmd, `--method=${opts.method}`);
		if (opts.body != null) {
			tmp = tmpname();
			writefile(tmp, type(opts.body) == 'string' ? opts.body : sprintf('%J', opts.body));
			push(cmd, '--body-file=' + shq(tmp));
		}
	}
	push(cmd, shq(url));
	// wget has no status code on stdout; exit code 0 == 2xx
	let out = run(join(' ', cmd) + ' 2>/dev/null; echo "\n__rc=$?"');
	if (tmp)
		unlink(tmp);
	if (out == null)
		return { status: 0, body: 'popen failed' };
	let i = rindex(out, '\n__rc=');
	let rc = +substr(out, i + 6);
	let body = substr(out, 0, i);
	return { status: rc == 0 ? 200 : 0, body, json: parse_json(body) };
};

export function request(url, opts) {
	opts ??= {};
	return opts.unix ? unix_request(url, opts) : wget_request(url, opts);
};

export function ok(r) {
	return r.status >= 200 && r.status < 300;
};
