<script setup lang="ts">
import { RouterView } from 'vue-router';
import { ToastViewport } from '@/components/primitives';
import AppNav from '@/components/layout/AppNav.vue';
</script>

<template>
  <AppNav />
  <RouterView />
  <ToastViewport />
</template>

<style>
/* Global styles live in styles/main.css; App.vue stays minimal. */
</style>
