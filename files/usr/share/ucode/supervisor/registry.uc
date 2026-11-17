'use strict';
// Registry v2 client: list tags of the configured image and find the newest.
import * as http from 'supervisor.http';
import { readfile, writefile, mkdir } from 'fs';
import { STATE_DIR } from 'supervisor.config';

export function split_image(image) {
	let i = index(image, '/');
	return { host: substr(image, 0, i), repo: substr(image, i + 1) };
};

function bearer(host, repo, cfg) {
	let r = http.request(`https://${host}/token?service=${host}&scope=repository:${repo}:pull`,
		{ user: cfg.registry_user ? `${cfg.registry_user}:${cfg.registry_pass}` : null });
	return http.ok(r) ? (r.json?.token ?? r.json?.access_token) : null;
};

// compare "2026.11.1-r2" style versions; returns -1/0/1
export function vcmp(a, b) {
	function parts(v) {
		let m = match(v, /^([0-9]+)\.([0-9]+)\.([0-9]+)(-r([0-9]+))?$/);
		return m ? [+m[1], +m[2], +m[3], +(m[5] ?? 0)] : [0, 0, 0, 0];
	}
	let x = parts(a), y = parts(b);
	for (let i = 0; i < 4; i++)
		if (x[i] != y[i])
			return x[i] < y[i] ? -1 : 1;
	return 0;
};

// All tags matching cfg.tag_regex. Registries return tags in pages sorted lexically, so the
// newest releases of a big repository (the official image has thousands of tags) are only on
// the last pages: follow `last=` until a page comes back empty. Any failed page aborts (null),
// because a partial list would make an old version look like the latest.
function fetch_tags(cfg) {
	let img = split_image(cfg.image);
	let host = img.host, repo = img.repo;
	let tok = bearer(host, repo, cfg);
	let headers = tok ? { Authorization: `Bearer ${tok}` } : {};
	let rx = regexp(cfg.tag_regex);
	let out = [], last = null;
	for (let page = 0; page < 60; page++) {
		let url = `https://${host}/v2/${repo}/tags/list?n=1000` + (last ? `&last=${last}` : '');
		let r = http.request(url, { headers });
		if (!http.ok(r) || !r.json)
			return null;
		let tags = r.json.tags ?? [];
		if (!length(tags))
			break;
		for (let t in tags)
			if (match(t, rx))
				push(out, t);
		last = tags[length(tags) - 1];
	}
	return length(out) ? out : null;
};

// Returns { latest, tags, checked } ; cached for cfg.cache_ttl seconds.
export function check(cfg, force) {
	mkdir(STATE_DIR);
	let cache = STATE_DIR + '/tags.json';
	if (!force) {
		let c = readfile(cache);
		if (c) {
			let j = json(c);
			if (j && j.image == cfg.image && time() - j.checked < +cfg.cache_ttl)
				return j;
		}
	}
	let tags = fetch_tags(cfg);
	if (!tags)
		return null;

	let rel = sort(tags, vcmp);
	let res = {
		image: cfg.image,
		checked: time(),
		tags: rel,
		latest: cfg.channel == 'latest' ? 'latest' : rel[length(rel) - 1]
	};
	writefile(cache, sprintf('%J', res));
	return res;
};
