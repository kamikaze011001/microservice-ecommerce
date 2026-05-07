import { defineStore } from 'pinia';
import { computed, ref } from 'vue';

export const AUTH_STORAGE_KEY = 'aibles.auth';

interface AuthRecord {
  accessToken: string;
  refreshToken: string;
}

function readStorage(): AuthRecord | null {
  const raw = localStorage.getItem(AUTH_STORAGE_KEY);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as AuthRecord;
  } catch {
    return null;
  }
}

export const useAuthStore = defineStore('auth', () => {
  const accessToken = ref<string | null>(null);
  const refreshToken = ref<string | null>(null);

  const isLoggedIn = computed(() => accessToken.value !== null);

  function login(tokens: AuthRecord) {
    accessToken.value = tokens.accessToken;
    refreshToken.value = tokens.refreshToken;
    localStorage.setItem(AUTH_STORAGE_KEY, JSON.stringify(tokens));
  }

  function clear() {
    accessToken.value = null;
    refreshToken.value = null;
    localStorage.removeItem(AUTH_STORAGE_KEY);
  }

  const persisted = readStorage();
  if (persisted) {
    accessToken.value = persisted.accessToken;
    refreshToken.value = persisted.refreshToken;
  }

  if (typeof window !== 'undefined') {
    window.addEventListener('storage', (e) => {
      if (e.key === AUTH_STORAGE_KEY && e.newValue === null) {
        accessToken.value = null;
        refreshToken.value = null;
      }
    });
  }

  return { accessToken, refreshToken, isLoggedIn, login, clear };
});
