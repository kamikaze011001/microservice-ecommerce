import { createApp, defineComponent, h } from 'vue';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { createPinia } from 'pinia';

export function withSetup<T>(composable: () => T): [T, ReturnType<typeof createApp>] {
  let result!: T;
  const app = createApp(
    defineComponent({
      setup() {
        result = composable();
        return () => h('div');
      },
    }),
  );
  app.use(createPinia());
  app.use(VueQueryPlugin, {
    queryClient: new QueryClient({ defaultOptions: { queries: { retry: false } } }),
  });
  app.mount(document.createElement('div'));
  return [result, app];
}
