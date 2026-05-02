<script setup lang="ts">
interface Props {
  inset?: string;
}
const props = withDefaults(defineProps<Props>(), { inset: '1rem' });
</script>

<template>
  <div class="b-cropmarks" :style="{ '--b-cropmarks-inset': props.inset }" aria-hidden="true">
    <span class="b-cropmarks__mark mark-tl" />
    <span class="b-cropmarks__mark mark-tr" />
    <span class="b-cropmarks__mark mark-bl" />
    <span class="b-cropmarks__mark mark-br" />
  </div>
</template>

<style scoped>
.b-cropmarks {
  position: relative;
  height: var(--space-8);
  margin: var(--space-8) 0;
}
.b-cropmarks__mark {
  position: absolute;
  width: 12px;
  height: 12px;
  border-color: var(--ink);
  border-style: solid;
  border-width: 0;
}
.mark-tl {
  top: var(--b-cropmarks-inset);
  left: var(--b-cropmarks-inset);
  border-top-width: 2px;
  border-left-width: 2px;
}
.mark-tr {
  top: var(--b-cropmarks-inset);
  right: var(--b-cropmarks-inset);
  border-top-width: 2px;
  border-right-width: 2px;
}
.mark-bl {
  bottom: var(--b-cropmarks-inset);
  left: var(--b-cropmarks-inset);
  border-bottom-width: 2px;
  border-left-width: 2px;
}
.mark-br {
  bottom: var(--b-cropmarks-inset);
  right: var(--b-cropmarks-inset);
  border-bottom-width: 2px;
  border-right-width: 2px;
}
</style>
