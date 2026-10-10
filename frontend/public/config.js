// Dev/preview-server stand-in. In the container, Caddy answers /config.js
// itself from the env's API_BASE_URL (see ../Caddyfile) and this file is
// never served. Empty = use the build-time VITE_API_BASE_URL.
window.__APP_CONFIG__ = window.__APP_CONFIG__ || {};
