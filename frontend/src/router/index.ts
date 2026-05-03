import { createRouter, createWebHistory } from 'vue-router';
import HomePage from '@/pages/HomePage.vue';
import DesignShowcase from '@/pages/DesignShowcase.vue';
import LoginPage from '@/pages/LoginPage.vue';
import RegisterPage from '@/pages/RegisterPage.vue';
import CartPage from '@/pages/CartPage.vue';
import ActivatePage from '@/pages/ActivatePage.vue';
import ProductDetailPage from '@/pages/ProductDetailPage.vue';
import NotFoundPage from '@/pages/NotFoundPage.vue';
import { useAuthStore } from '@/stores/auth';

export const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/', component: HomePage },
    { path: '/_design', component: DesignShowcase },
    { path: '/login', component: LoginPage, meta: { guestOnly: true } },
    { path: '/register', component: RegisterPage, meta: { guestOnly: true } },
    { path: '/activate', component: ActivatePage, meta: { guestOnly: true } },
    { path: '/cart', component: CartPage, meta: { requiresAuth: true } },
    { path: '/products/:id', component: ProductDetailPage },
    { path: '/:pathMatch(.*)*', component: NotFoundPage },
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
