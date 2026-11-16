'use strict';
// Background jobs: state kept in STATE_DIR/jobs/<id>.json, work done by CLI subprocess.
import { readfile, writefile, mkdir } from 'fs';
import { rand } from 'math';
import { STATE_DIR } from 'supervisor.config';

const DIR = STATE_DIR + '/jobs';

export function path(id) {
	return `${DIR}/${replace(id, /[^a-z0-9-]/g, '')}.json`;
};

export function write(id, data) {
	mkdir(STATE_DIR);
	mkdir(DIR);
	writefile(path(id), sprintf('%J', data));
};

export function get(id) {
	let c = readfile(path(id));
	return c ? json(c) : null;
};

export function update(id, patch) {
	let j = get(id) ?? {};
	for (let k, v in patch)
		j[k] = v;
	write(id, j);
};

// Start `owrt-supervisor <cmd> <args> --job <id>` detached.
export function spawn(cmd, args) {
	let id = sprintf('%d-%d', time(), rand() % 10000);
	write(id, { uuid: id, name: cmd, done: false, progress: 0, stage: 'queued', errors: [] });
	system(`/usr/sbin/owrt-supervisor ${cmd} ${args ?? ''} --job ${id} >/dev/null 2>&1 &`);
	return id;
};
