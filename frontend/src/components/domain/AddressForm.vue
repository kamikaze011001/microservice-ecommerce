<script setup lang="ts">
import { useForm } from 'vee-validate';
import { toTypedSchema } from '@vee-validate/zod';
import { addressSchema, type AddressInput } from '@/lib/zod-schemas';
import { formatAddress } from '@/lib/format';

const props = defineProps<{
  initial?: AddressInput;
  pending?: boolean;
}>();

const emit = defineEmits<{
  (e: 'submit', payload: { structured: AddressInput; address: string; phone: string }): void;
}>();

const { handleSubmit, errors, defineField } = useForm({
  validationSchema: toTypedSchema(addressSchema),
  initialValues: props.initial ?? {
    street: '',
    city: '',
    state: '',
    postcode: '',
    country: 'US',
    phone: '',
  },
});

const [street, streetAttrs] = defineField('street');
const [city, cityAttrs] = defineField('city');
const [state, stateAttrs] = defineField('state');
const [postcode, postcodeAttrs] = defineField('postcode');
const [country, countryAttrs] = defineField('country');
const [phone, phoneAttrs] = defineField('phone');

const onSubmit = handleSubmit((values) => {
  emit('submit', {
    structured: values,
    address: formatAddress(values),
    phone: values.phone,
  });
});
</script>

<template>
  <form class="address" novalidate @submit.prevent="onSubmit">
    <div class="address__row">
      <label for="street">STREET</label>
      <input id="street" v-model="street" v-bind="streetAttrs" />
      <p v-if="errors.street" class="address__err">{{ errors.street }}</p>
    </div>
    <div class="address__row">
      <label for="city">CITY</label>
      <input id="city" v-model="city" v-bind="cityAttrs" />
      <p v-if="errors.city" class="address__err">{{ errors.city }}</p>
    </div>
    <div class="address__row address__row--split">
      <div>
        <label for="state">STATE / REGION</label>
        <input id="state" v-model="state" v-bind="stateAttrs" />
        <p v-if="errors.state" class="address__err">{{ errors.state }}</p>
      </div>
      <div>
        <label for="postcode">POSTCODE</label>
        <input id="postcode" v-model="postcode" v-bind="postcodeAttrs" />
        <p v-if="errors.postcode" class="address__err">{{ errors.postcode }}</p>
      </div>
    </div>
    <div class="address__row">
      <label for="country">COUNTRY (ISO-2)</label>
      <input id="country" v-model="country" v-bind="countryAttrs" maxlength="2" />
      <p v-if="errors.country" class="address__err">{{ errors.country }}</p>
    </div>
    <div class="address__row">
      <label for="phone">PHONE</label>
      <input id="phone" v-model="phone" v-bind="phoneAttrs" type="tel" />
      <p v-if="errors.phone" class="address__err">{{ errors.phone }}</p>
    </div>
    <button type="submit" class="address__submit" :disabled="pending">
      {{ pending ? 'STAMPING…' : 'CONTINUE TO PAYMENT' }}
    </button>
  </form>
</template>

<style scoped>
.address {
  display: flex;
  flex-direction: column;
  gap: var(--space-4);
}
.address__row {
  display: flex;
  flex-direction: column;
  gap: var(--space-1);
}
.address__row label {
  font-family: var(--font-mono);
  font-size: 0.85em;
}
.address__row input {
  border: 2px solid var(--color-ink);
  padding: var(--space-2) var(--space-3);
  font-family: var(--font-display);
  background: var(--color-paper);
}
.address__row--split {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: var(--space-4);
}
.address__err {
  color: var(--color-spot);
  font-family: var(--font-mono);
  font-size: 0.85em;
  margin: 0;
}
.address__submit {
  background: var(--color-spot);
  color: var(--color-paper);
  border: 2px solid var(--color-ink);
  padding: var(--space-3) var(--space-5);
  font-family: var(--font-display);
  font-size: 1.1em;
  cursor: pointer;
}
.address__submit:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}
</style>
