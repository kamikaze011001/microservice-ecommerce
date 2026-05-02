import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import type { App } from 'vue';
import { ApiError } from '@/api/error';

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      retry: (failureCount, error) => {
        if (error instanceof ApiError && error.status >= 500) return failureCount < 3;
        return false;
      },
      retryDelay: (attempt) => Math.min(1000 * 2 ** attempt, 8000),
      staleTime: 30_000,
    },
    mutations: { retry: false },
  },
});

export function installVueQuery(app: App) {
  app.use(VueQueryPlugin, { queryClient });
}
