import http from 'k6/http';
import { config } from '../config.js';

// Per-VU token storage
const tokenStore = {};

export function initTokens(vu, accessToken, refreshToken) {
  tokenStore[vu] = {
    accessToken,
    refreshToken,
    obtainedAt: Date.now()
  };
}

export function getAccessToken(vu) {
  const store = tokenStore[vu];
  if (!store) return null;

  // Check if token needs refresh (2 min before expiry)
  const tokenAge = Date.now() - store.obtainedAt;
  const needsRefresh = tokenAge > (config.token.accessTokenTTL - config.token.refreshBeforeExpiry);

  if (needsRefresh) {
    refreshTokens(vu);
  }

  return tokenStore[vu].accessToken;
}

function refreshTokens(vu) {
  const store = tokenStore[vu];

  const res = http.post(
    `${config.baseUrl}${config.endpoints.refreshToken}`,
    null,
    {
      headers: {
        'Authorization': `Bearer ${store.refreshToken}`,
        'Content-Type': 'application/json'
      },
      tags: { name: 'refresh_token' }
    }
  );

  if (res.status === 200) {
    const data = res.json('data');
    tokenStore[vu] = {
      accessToken: data.access_token,
      refreshToken: data.refresh_token,
      obtainedAt: Date.now()
    };
    console.log(`VU ${vu}: Token refreshed successfully`);
  } else {
    console.error(`VU ${vu}: Token refresh failed: ${res.status}`);
  }
}

export function getAuthHeaders(vu) {
  const token = getAccessToken(vu);
  return {
    'Authorization': `Bearer ${token}`,
    'Content-Type': 'application/json'
  };
}
