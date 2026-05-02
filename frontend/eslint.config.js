import js from '@eslint/js';
import vue from 'eslint-plugin-vue';
import tseslint from 'typescript-eslint';
import prettier from 'eslint-config-prettier/flat';
import globals from 'globals';

export default [
  {
    ignores: ['dist', 'node_modules', 'coverage', '*.config.js', '*.config.ts', 'public'],
  },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  ...vue.configs['flat/recommended'],
  {
    files: ['**/*.{ts,vue}'],
    languageOptions: {
      ecmaVersion: 'latest',
      sourceType: 'module',
      globals: { ...globals.browser },
      parserOptions: {
        parser: tseslint.parser,
      },
    },
    rules: {
      'vue/multi-word-component-names': 'off',
      'vue/component-name-in-template-casing': ['error', 'PascalCase'],
      '@typescript-eslint/consistent-type-imports': 'error',
      '@typescript-eslint/no-unused-vars': ['error', { argsIgnorePattern: '^_' }],
      'no-console': ['warn', { allow: ['warn', 'error'] }],
    },
  },
  prettier,
];
