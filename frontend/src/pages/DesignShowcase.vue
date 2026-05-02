<script setup lang="ts">
import {
  BButton,
  BCard,
  BInput,
  BStamp,
  BTag,
  BCropmarks,
  BMarginNumeral,
  BDialog,
  BSelect,
} from '@/components/primitives';
import { ref } from 'vue';
import { useToast } from '@/composables/useToast';

const toast = useToast();
const inputValue = ref('');
const inputErr = ref('');
const dialogOpen = ref(false);
const selectValue = ref('');
const countries = [
  { value: 'us', label: 'United States' },
  { value: 'vn', label: 'Vietnam' },
  { value: 'jp', label: 'Japan' },
];
</script>

<template>
  <main class="showcase">
    <h1 class="showcase__title">DESIGN SHOWCASE</h1>
    <p class="showcase__lede">Every primitive, every variant. /_design — not linked from nav.</p>

    <!-- 01 BButton -->
    <section class="showcase__section">
      <BMarginNumeral numeral="01" />
      <h2>BButton</h2>
      <div class="grid">
        <BButton variant="ink">INK</BButton>
        <BButton variant="spot">SPOT</BButton>
        <BButton variant="ghost">GHOST</BButton>
        <BButton variant="danger">DANGER</BButton>
        <BButton disabled>DISABLED</BButton>
        <BButton loading>LOADING</BButton>
      </div>
    </section>
    <BCropmarks />

    <!-- 02 BCard -->
    <section class="showcase__section">
      <BMarginNumeral numeral="02" />
      <h2>BCard</h2>
      <div class="grid grid--cards">
        <BCard
          ><h3>STRAIGHT</h3>
          <p>No rotation.</p></BCard
        >
        <BCard :rotate="1.5"
          ><h3>TILTED</h3>
          <p>+1.5°</p></BCard
        >
        <BCard hover-misregister
          ><h3>HOVER ME</h3>
          <p>Misregistration on hover.</p></BCard
        >
      </div>
    </section>
    <BCropmarks />

    <!-- 03 BInput -->
    <section class="showcase__section">
      <BMarginNumeral numeral="03" />
      <h2>BInput</h2>
      <div class="grid grid--stack">
        <BInput v-model="inputValue" label="Default" placeholder="Type something" />
        <BInput v-model="inputErr" label="Error state" error="This field is required" />
        <BInput :model-value="''" label="Disabled" disabled placeholder="Locked" />
      </div>
    </section>
    <BCropmarks />

    <!-- 04 BStamp -->
    <section class="showcase__section">
      <BMarginNumeral numeral="04" />
      <h2>BStamp</h2>
      <div class="grid grid--stamps">
        <BStamp tone="red" size="sm">PAID</BStamp>
        <BStamp tone="ink" size="md">SHIPPED</BStamp>
        <BStamp tone="spot" size="lg" :rotate="-4">SOLD OUT</BStamp>
      </div>
    </section>
    <BCropmarks />

    <!-- 05 BTag -->
    <section class="showcase__section">
      <BMarginNumeral numeral="05" />
      <h2>BTag</h2>
      <div class="grid">
        <BTag tone="ink">INK</BTag>
        <BTag tone="spot" :rotate="2">SPOT</BTag>
        <BTag tone="paper">PAPER</BTag>
      </div>
    </section>
    <BCropmarks />

    <!-- 06 BCropmarks -->
    <section class="showcase__section">
      <BMarginNumeral numeral="06" />
      <h2>BCropmarks</h2>
      <p>Already used as section dividers. Custom inset:</p>
      <BCropmarks inset="3rem" />
    </section>
    <BCropmarks />

    <!-- 07 BMarginNumeral -->
    <section class="showcase__section">
      <BMarginNumeral numeral="07" />
      <h2>BMarginNumeral</h2>
      <div class="grid grid--two">
        <BMarginNumeral numeral="L" side="left" />
        <BMarginNumeral numeral="R" side="right" />
      </div>
    </section>
    <BCropmarks />

    <!-- 08 BDialog -->
    <section class="showcase__section">
      <BMarginNumeral numeral="08" />
      <h2>BDialog</h2>
      <BButton variant="ink" @click="dialogOpen = true">OPEN DIALOG</BButton>
      <BDialog
        v-model:open="dialogOpen"
        title="Confirm action"
        description="Press Esc or click × to close."
      >
        <p>This is the dialog body. Tab cycles within the dialog (focus trap from Reka UI).</p>
        <template #footer>
          <BButton variant="ghost" @click="dialogOpen = false">CANCEL</BButton>
          <BButton variant="spot" @click="dialogOpen = false">CONFIRM</BButton>
        </template>
      </BDialog>
    </section>
    <BCropmarks />

    <!-- 09 BSelect -->
    <section class="showcase__section">
      <BMarginNumeral numeral="09" />
      <h2>BSelect</h2>
      <div class="grid grid--stack">
        <BSelect v-model="selectValue" :options="countries" placeholder="Choose country" />
        <BSelect :model-value="''" :options="countries" placeholder="With error" error="Pick one" />
      </div>
    </section>
    <BCropmarks />

    <!-- 10 BToast -->
    <section class="showcase__section">
      <BMarginNumeral numeral="10" />
      <h2>BToast</h2>
      <div class="grid">
        <BButton variant="ink" @click="toast.info('Info', 'Just so you know.')">FIRE INFO</BButton>
        <BButton variant="spot" @click="toast.success('Saved!', 'All changes persisted.')"
          >FIRE SUCCESS</BButton
        >
        <BButton variant="danger" @click="toast.error('Failed', 'Something went wrong.')"
          >FIRE ERROR</BButton
        >
      </div>
    </section>
  </main>
</template>

<style scoped>
.showcase {
  max-width: var(--container-max);
  margin: 0 auto;
  padding: var(--space-12) var(--space-8);
  font-family: var(--font-body);
}
.showcase__title {
  font-family: var(--font-display);
  font-size: var(--type-display);
  font-weight: 900;
  text-transform: uppercase;
  letter-spacing: -0.02em;
}
.showcase__lede {
  color: var(--muted-ink);
  margin-bottom: var(--space-8);
}
.showcase__section {
  margin: var(--space-12) 0;
}
.showcase__section h2 {
  font-family: var(--font-display);
  font-size: var(--type-h2);
  text-transform: uppercase;
  letter-spacing: 0.04em;
  margin-bottom: var(--space-6);
}
.grid {
  display: flex;
  flex-wrap: wrap;
  gap: var(--space-4);
  align-items: center;
}
.grid--cards {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: var(--space-6);
}
.grid--stack {
  flex-direction: column;
  align-items: stretch;
  max-width: 24rem;
}
.grid--stamps {
  gap: var(--space-8);
}
.grid--two {
  display: flex;
  justify-content: space-between;
}
</style>
