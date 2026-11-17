'use strict';
// UCI-backed configuration with defaults.
import { cursor } from 'uci';
import { popen, stat } from 'fs';

const CATALOG_DIR = '/usr/share/ha-supervisor';

const DEFAULTS = {
	image: '',                            // '' = official image, or the armv7 community build (see CORE_IMAGES)
	arch: '',                             // '' = detected (uname -m); set to override
	container: 'homeassistant',
	config_dir: '/srv/homeassistant/config',
	timezone: '',                         // '' = follow the system zone (system.@system[0].zonename)
	port: '8124',                         // supervisor API port (127.0.0.1)
	token: '',
	channel: 'stable',                    // stable = skip non-release tags, latest = follow :latest
	tag_regex: '^[0-9]{4}\\.[0-9]+\\.[0-9]+(-r[0-9]+)?$',
	core_port: '8123',                    // Home Assistant's HTTP port (passed as SETUP_PORT, see docker.uc)
	health_url: '',                       // '' = http://127.0.0.1:<core_port>/manifest.json
	health_timeout: '300',
	registry_user: '',
	registry_pass: '',
	cache_ttl: '3600',
	core_socket: '/var/run/ha-supervisor/core/core.sock',   // HA's Supervisor-only unix socket (host side)
	bridge_ip: '172.17.0.1',               // docker bridge gateway: add-ons reach the API here
	catalog: '',                          // '' = /usr/share/ha-supervisor/catalog-<arch>.json (StoreInfo JSON)
	devices: [],                          // list of /dev/... passthrough
	backup_before_update: '0',            // policy when the caller does not say; request flag wins
	backup_dir: '/mnt/docker/ha-supervisor-backups',
};

// uname -m -> Supervisor architecture names
const ARCH_MAP = {
	armv7l: 'armv7', armv8l: 'armv7', armv6l: 'armhf', aarch64: 'aarch64', arm64: 'aarch64',
	x86_64: 'amd64', amd64: 'amd64', i686: 'i386', i386: 'i386'
};

// Home Assistant Core image per architecture. The official image is multi-arch for amd64 and
// aarch64 only; upstream dropped armv7, so that one comes from a community build.
const CORE_IMAGES = {
	aarch64: 'ghcr.io/home-assistant/home-assistant',
	amd64: 'ghcr.io/home-assistant/home-assistant',
	armv7: 'ghcr.io/adyoull/ha-armv7'
};

export function detect_arch() {
	let m = getenv('HA_SUPERVISOR_ARCH');   // test override
	if (!m) {
		let p = popen('uname -m', 'r');
		m = p ? trim(p.read('all')) : '';
		if (p) p.close();
	}
	return ARCH_MAP[m] ?? m;
};

export function load() {
	let c = cursor();
	let s = c.get_all('ha-supervisor', 'main') ?? {};
	let cfg = {};
	for (let k, v in DEFAULTS)
		cfg[k] = s[k] ?? v;
	if (!cfg.timezone)
		cfg.timezone = c.get('system', '@system[0]', 'zonename') || 'UTC';
	cfg.health_url = cfg.health_url || `http://127.0.0.1:${cfg.core_port}/manifest.json`;
	cfg.arch = cfg.arch || detect_arch();
	cfg.image = cfg.image || CORE_IMAGES[cfg.arch] || '';
	cfg.catalog = cfg.catalog || `${CATALOG_DIR}/catalog-${cfg.arch}.json`;
	return cfg;
};

export function set(key, value) {
	let c = cursor();
	if (!c.get('ha-supervisor', 'main'))
		c.set('ha-supervisor', 'main', 'supervisor');
	c.set('ha-supervisor', 'main', key, value);
	c.save('ha-supervisor');
	c.commit('ha-supervisor');
};

// Called at install/upgrade: write the detected architecture, the image and the catalog into
// /etc/config/ha-supervisor so they are explicit and editable. Only options that are not set
// yet are written; whatever the user chose stays. Returns a list of what was written.
export function init_defaults() {
	let c = cursor();
	let s = c.get_all('ha-supervisor', 'main') ?? {};
	let arch = s.arch || detect_arch();
	let want = {
		arch,
		image: CORE_IMAGES[arch],                                     // undefined: no image for this arch
		catalog: `${CATALOG_DIR}/catalog-${arch}.json`
	};
	let written = [];
	for (let k, v in want) {
		if (s[k] || !v)
			continue;
		if (k == 'catalog' && !stat(v))          // no catalog shipped for this architecture
			continue;
		set(k, v);
		push(written, `${k}=${v}`);
	}
	return written;
};


export const STATE_DIR = '/var/run/ha-supervisor';
export const VERSION = '0.1.0';
