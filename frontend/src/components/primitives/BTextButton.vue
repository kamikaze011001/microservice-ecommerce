<script setup lang="ts">
interface Props {
  type?: 'button' | 'submit' | 'reset';
  disabled?: boolean;
}
const props = withDefaults(defineProps<Props>(), {
  type: 'button',
  disabled: false,
});
// A semantic <button> that reads as inline text — for actions dressed as links
// (a nav "LOG OUT", a cart "Remove", an inline "Cancel"). It inherits the
// surrounding typography and yields to any consumer class (see the :where()
// note in the style block). @click / class / data-* fall through to the root.
</script>

<template>
  <button :type="props.type" :disabled="props.disabled" class="b-text-button">
    <slot />
  </button>
</template>

<style scoped>
/*
 * :where() gives this reset ZERO specificity, so a consumer class always wins
 * the font/color/letter-spacing cascade regardless of stylesheet load order.
 * That's deliberate: BTextButton is meant to take on the typography of wherever
 * it sits, unlike BButton which owns its look. `font: inherit` (author origin)
 * still beats the UA button font for the un-classed, blend-into-prose case.
 */
:where(.b-text-button) {
  display: inline;
  margin: 0;
  padding: 0;
  background: transparent;
  border: 0;
  font: inherit;
  color: inherit;
  letter-spacing: inherit;
  text-align: inherit;
  cursor: pointer;
}
.b-text-button:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}
</style>
