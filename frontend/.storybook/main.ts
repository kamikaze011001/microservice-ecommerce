import type { StorybookConfig } from '@storybook/vue3-vite';
import { fileURLToPath, URL } from 'node:url';
import path from 'node:path';

const config: StorybookConfig = {
  stories: ['../src/**/*.mdx', '../src/**/*.stories.@(ts|tsx)'],
  addons: ['@storybook/addon-docs', '@storybook/addon-a11y'],
  framework: {
    name: '@storybook/vue3-vite',
    options: {},
  },
  viteFinal: async (cfg) => {
    cfg.resolve ??= {};
    cfg.resolve.alias = {
      ...(cfg.resolve.alias ?? {}),
      '@': fileURLToPath(new URL('../src', import.meta.url)),
    };
    // Workaround for storybookjs/storybook#33537: Storybook 10.4.x's MDX compiler
    // injects a malformed `file://./…` providerImportSource specifier (host "."
    // instead of an absolute path) for `mdx-react-shim.js`, which Rollup cannot
    // resolve — breaking every `.mdx` build. Rewrite any `file://`-prefixed import
    // specifier back to a real cwd-relative filesystem path before resolution.
    cfg.plugins ??= [];
    cfg.plugins.unshift({
      name: 'sb-mdx-file-url-shim-fix',
      enforce: 'pre',
      resolveId(source: string) {
        if (source.startsWith('file://')) {
          return path.resolve(process.cwd(), source.replace(/^file:\/\//, ''));
        }
        return null;
      },
    });
    return cfg;
  },
};

export default config;
