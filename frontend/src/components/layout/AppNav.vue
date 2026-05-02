<script setup lang="ts">
import { computed } from 'vue';
import { RouterLink, useRouter } from 'vue-router';
import { storeToRefs } from 'pinia';
import { useAuthStore } from '@/stores/auth';
import { useLogout } from '@/api/queries/auth';
import { BButton } from '@/components/primitives';

const auth = useAuthStore();
const { isLoggedIn, username } = storeToRefs(auth);
const logout = useLogout();
const router = useRouter();

const greeting = computed(() => (username.value ? `@${username.value}` : ''));

function onLogout() {
  logout();
  router.push('/');
}
</script>

<template>
  <nav class="app-nav">
    <RouterLink to="/" class="app-nav__brand">ISSUE Nº01</RouterLink>
    <div class="app-nav__right">
      <template v-if="isLoggedIn">
        <span class="app-nav__user" data-testid="nav-user">{{ greeting }}</span>
        <BButton variant="ghost" data-testid="nav-logout" @click="onLogout"> LOG OUT </BButton>
      </template>
      <template v-else>
        <RouterLink to="/login" data-testid="nav-login">
          <BButton variant="ghost">LOG IN</BButton>
        </RouterLink>
      </template>
    </div>
  </nav>
</template>

<style scoped>
.app-nav {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: var(--space-3) var(--space-6);
  border-bottom: var(--border-thick);
  background: var(--paper);
}
.app-nav__brand {
  font-family: var(--font-display);
  font-size: 1.25rem;
  letter-spacing: 0.04em;
  color: var(--ink);
  text-decoration: none;
}
.app-nav__right {
  display: flex;
  align-items: center;
  gap: var(--space-3);
}
.app-nav__user {
  font-family: var(--font-mono);
  font-size: 0.875rem;
  color: var(--muted-ink);
}
</style>
