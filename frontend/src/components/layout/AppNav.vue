<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import { RouterLink, useRouter, useRoute } from 'vue-router';
import { storeToRefs } from 'pinia';
import { useAuthStore } from '@/stores/auth';
import { useLogout } from '@/api/queries/auth';
import { useProfileQuery } from '@/api/queries/profile';
import { BButton } from '@/components/primitives';

const auth = useAuthStore();
const { isLoggedIn } = storeToRefs(auth);
const logout = useLogout();
const router = useRouter();
const route = useRoute();

const profile = useProfileQuery({ enabled: isLoggedIn });
const greeting = computed(() => {
  const name = profile.data.value?.name?.trim();
  return name ? `HI, ${name.toUpperCase()}` : '';
});

const menuOpen = ref(false);
function toggleMenu() {
  menuOpen.value = !menuOpen.value;
}
// close on route change
watch(
  () => route.fullPath,
  () => {
    menuOpen.value = false;
  },
);

function onLogout() {
  logout();
  menuOpen.value = false;
  router.push('/');
}
</script>

<template>
  <nav class="app-nav" :class="{ 'is-open': menuOpen }">
    <div class="app-nav__bar">
      <RouterLink to="/" class="app-nav__brand">ISSUE Nº01</RouterLink>
      <button
        type="button"
        class="app-nav__toggle"
        :aria-expanded="menuOpen"
        aria-controls="app-nav-menu"
        :aria-label="menuOpen ? 'Close menu' : 'Open menu'"
        @click="toggleMenu"
      >
        <span class="app-nav__toggle-bar" aria-hidden="true" />
        <span class="app-nav__toggle-bar" aria-hidden="true" />
        <span class="app-nav__toggle-bar" aria-hidden="true" />
      </button>
      <div class="app-nav__right">
        <template v-if="isLoggedIn">
          <span class="app-nav__user" data-testid="nav-user">{{ greeting }}</span>
          <RouterLink to="/account" class="app-nav__account">ACCOUNT</RouterLink>
          <BButton variant="ghost" data-testid="nav-logout" @click="onLogout"> LOG OUT </BButton>
        </template>
        <template v-else>
          <RouterLink to="/login" data-testid="nav-login">
            <BButton variant="ghost">LOG IN</BButton>
          </RouterLink>
        </template>
      </div>
    </div>
    <div id="app-nav-menu" class="app-nav__menu" :hidden="!menuOpen">
      <template v-if="isLoggedIn">
        <span class="app-nav__menu-user">{{ greeting }}</span>
        <RouterLink to="/account" class="app-nav__menu-link">ACCOUNT</RouterLink>
        <button
          type="button"
          class="app-nav__menu-link"
          data-testid="nav-logout-mobile"
          @click="onLogout"
        >
          LOG OUT
        </button>
      </template>
      <template v-else>
        <RouterLink to="/login" class="app-nav__menu-link" data-testid="nav-login-mobile"
          >LOG IN</RouterLink
        >
      </template>
    </div>
  </nav>
</template>

<style scoped>
.app-nav {
  border-bottom: var(--border-thick);
  background: var(--paper);
}
.app-nav__bar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: var(--space-3) var(--space-4);
  gap: var(--space-3);
}
.app-nav__brand {
  font-family: var(--font-display);
  font-size: 1.25rem;
  letter-spacing: 0.04em;
  color: var(--ink);
  text-decoration: none;
}
.app-nav__toggle {
  display: flex;
  flex-direction: column;
  justify-content: space-between;
  width: 2rem;
  height: 1.5rem;
  background: transparent;
  border: 0;
  padding: 0;
  cursor: pointer;
}
.app-nav__toggle-bar {
  display: block;
  width: 100%;
  height: 3px;
  background: var(--ink);
}
.app-nav__right {
  display: none;
}
.app-nav__menu {
  display: flex;
  flex-direction: column;
  gap: var(--space-3);
  padding: var(--space-4);
  border-top: var(--border-thin);
}
.app-nav__menu[hidden] {
  display: none;
}
.app-nav__menu-user {
  font-family: var(--font-mono);
  font-size: 0.875rem;
  color: var(--muted-ink);
}
.app-nav__menu-link {
  font-family: var(--font-mono);
  font-size: 1rem;
  letter-spacing: 0.08em;
  color: var(--ink);
  text-decoration: none;
  background: transparent;
  border: 0;
  padding: 0;
  text-align: left;
  cursor: pointer;
}
.app-nav__user {
  font-family: var(--font-mono);
  font-size: 0.875rem;
  color: var(--muted-ink);
}
.app-nav__account {
  font-family: var(--font-mono);
  font-size: 0.875rem;
  letter-spacing: 0.08em;
  color: var(--ink);
  text-decoration: none;
}

/* Tablet+ : show the inline links, hide the hamburger and the dropdown panel */
@media (min-width: 48rem) {
  .app-nav__bar {
    padding: var(--space-3) var(--space-6);
  }
  .app-nav__toggle {
    display: none;
  }
  .app-nav__right {
    display: flex;
    align-items: center;
    gap: var(--space-3);
  }
  .app-nav__menu {
    display: none !important;
  }
}
</style>
