'use strict';
// UCI-backed configuration with defaults.
import { cursor } from 'uci';

const DEFAULTS = {
	image: 'ghcr.io/adyoull/ha-armv7',   // image source (no tag)
	container: 'homeassistant',
	config_dir: '/srv/homeassistant/config',
	timezone: 'UTC',
	port: '8124',                         // supervisor API port (127.0.0.1)
	token: '',
	channel: 'stable',                    // stable = skip non-release tags, latest = follow :latest
	tag_regex: '^[0-9]{4}\\.[0-9]+\\.[0-9]+(-r[0-9]+)?$',
	health_url: 'http://127.0.0.1:8123/manifest.json',
	health_timeout: '300',
	registry_user: '',
	registry_pass: '',
	cache_ttl: '3600',
	bridge_ip: '172.17.0.1',               // docker bridge gateway: add-ons reach the API here
	catalog: '/usr/share/owrt-supervisor/catalog.json',   // add-on catalog (StoreInfo JSON)
	devices: [],                          // list of /dev/... passthrough
	backup_before_update: '1'
};

export function load() {
	let c = cursor();
	let s = c.get_all('owrt-supervisor', 'main') ?? {};
	let cfg = {};
	for (let k, v in DEFAULTS)
		cfg[k] = s[k] ?? v;
	return cfg;
};

export function set(key, value) {
	let c = cursor();
	if (!c.get('owrt-supervisor', 'main'))
		c.set('owrt-supervisor', 'main', 'supervisor');
	c.set('owrt-supervisor', 'main', key, value);
	c.save('owrt-supervisor');
	c.commit('owrt-supervisor');
};

export const STATE_DIR = '/var/run/owrt-supervisor';
export const VERSION = '0.1.0';
