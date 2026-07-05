import { setup, type Preview } from '@storybook/vue3-vite';
import { createPinia } from 'pinia';
import { createRouter, createMemoryHistory } from 'vue-router';
import '@/styles/tokens.css';
import '@/styles/fonts.css';
import '@/styles/main.css';

setup((app) => {
  app.use(createPinia());
  app.use(
    createRouter({
      history: createMemoryHistory(),
      routes: [{ path: '/', component: { template: '<div/>' } }],
    }),
  );
});

const preview: Preview = {
  parameters: {
    backgrounds: {
      default: 'paper',
      values: [
        { name: 'paper', value: '#F4EFE6' },
        { name: 'ink', value: '#1C1C1C' },
      ],
    },
    controls: { expanded: true },
    a11y: { test: 'error' },
  },
};

export default preview;
