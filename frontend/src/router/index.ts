import { createRouter, createWebHistory } from 'vue-router';
import HomePlaceholder from '@/pages/HomePlaceholder.vue';
import DesignShowcase from '@/pages/DesignShowcase.vue';

export const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/', component: HomePlaceholder },
    { path: '/_design', component: DesignShowcase },
  ],
});
