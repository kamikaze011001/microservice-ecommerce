import { createRouter, createWebHistory } from 'vue-router';
import HomePlaceholder from '@/pages/HomePlaceholder.vue';
import DesignShowcase from '@/pages/DesignShowcase.vue';
import LoginPage from '@/pages/LoginPage.vue';
import RegisterPage from '@/pages/RegisterPage.vue';
import CartPlaceholder from '@/pages/CartPlaceholder.vue';
import { useAuthStore } from '@/stores/auth';

export const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/', component: HomePlaceholder },
    { path: '/_design', component: DesignShowcase },
    { path: '/login', component: LoginPage, meta: { guestOnly: true } },
    { path: '/register', component: RegisterPage, meta: { guestOnly: true } },
    { path: '/cart', component: CartPlaceholder, meta: { requiresAuth: true } },
  ],
});

router.beforeEach((to) => {
  const auth = useAuthStore();
  if (to.meta.requiresAuth && !auth.isLoggedIn) {
    return { path: '/login', query: { next: to.fullPath } };
  }
  if (to.meta.guestOnly && auth.isLoggedIn) {
    return { path: '/' };
  }
});
