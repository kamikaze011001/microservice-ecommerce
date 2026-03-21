import http from 'k6/http';
import { check } from 'k6';
import { config } from '../config.js';
import { initTokens } from './token-manager.js';

export function login(vu, username, password) {
  const url = `${config.baseUrl}${config.endpoints.login}`;

  const res = http.post(url, JSON.stringify({ username, password }), {
    headers: { 'Content-Type': 'application/json' },
    tags: { name: 'login' }
  });

  const success = check(res, {
    'login status 200': (r) => r.status === 200,
    'has access_token': (r) => r.json('data.access_token') !== undefined,
    'has refresh_token': (r) => r.json('data.refresh_token') !== undefined
  });

  if (success) {
    const data = res.json('data');
    initTokens(vu, data.access_token, data.refresh_token);
    return data;
  }

  return null;
}

// Login without token storage (for setup)
export function loginSimple(username, password) {
  const url = `${config.baseUrl}${config.endpoints.login}`;

  const res = http.post(url, JSON.stringify({ username, password }), {
    headers: { 'Content-Type': 'application/json' },
    tags: { name: 'admin_login' }
  });

  if (res.status === 200) {
    return res.json('data');
  }
  return null;
}
