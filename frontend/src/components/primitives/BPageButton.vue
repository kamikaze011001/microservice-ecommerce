<script setup lang="ts">
interface Props {
  active?: boolean;
  type?: 'button' | 'submit' | 'reset';
}
const props = withDefaults(defineProps<Props>(), { active: false, type: 'button' });
</script>

<template>
  <button :type="props.type" class="b-page-button" :data-active="props.active ? 'true' : 'false'">
    <slot />
  </button>
</template>

<style scoped>
.b-page-button {
  border: var(--border-thin);
  background: transparent;
  padding: var(--space-2) var(--space-3);
  cursor: pointer;
  color: var(--ink);
  font-family: var(--font-mono);
  font-size: var(--type-mono);
}
.b-page-button[data-active='true'] {
  background: var(--spot);
  color: var(--ink);
  border-color: var(--ink);
}
</style>
