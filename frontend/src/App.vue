<script setup lang="ts">
import { RouterView } from 'vue-router';
import { ToastViewport } from '@/components/primitives';
import AppNav from '@/components/layout/AppNav.vue';
</script>

<template>
  <a href="#main" class="skip-link">Skip to content</a>
  <AppNav />
  <div id="main" tabindex="-1">
    <RouterView />
  </div>
  <ToastViewport />
</template>

<style>
/* Global styles live in styles/main.css; App.vue stays minimal. */
</style>
