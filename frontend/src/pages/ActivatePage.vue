<script setup lang="ts">
import { computed, onBeforeUnmount, ref } from 'vue';
import { useForm } from 'vee-validate';
import { toTypedSchema } from '@vee-validate/zod';
import { useRoute, useRouter } from 'vue-router';
import { activateSchema } from '@/lib/zod-schemas';
import { useActivateMutation, useResendOtpMutation } from '@/api/queries/auth';
import { BButton, BInput } from '@/components/primitives';

const route = useRoute();
const router = useRouter();
const activate = useActivateMutation();
const resend = useResendOtpMutation();

const queryEmail = typeof route.query.email === 'string' ? route.query.email : '';
const emailLocked = ref(queryEmail.length > 0);

const { handleSubmit, errors, defineField, setErrors } = useForm({
  validationSchema: toTypedSchema(activateSchema),
  initialValues: { email: queryEmail, otp: '' },
});

const [emailModel, emailAttrs] = defineField('email');
const [otpModel, otpAttrs] = defineField('otp');
const email = computed({
  get: () => emailModel.value ?? '',
  set: (v) => {
    emailModel.value = v;
  },
});
const otp = computed({
  get: () => otpModel.value ?? '',
  set: (v) => {
    otpModel.value = v;
  },
});

const pending = computed(() => activate.isPending?.value === true);

const onSubmit = handleSubmit(async (values) => {
  try {
    await activate.mutateAsync(values);
    await router.push('/login');
  } catch (err) {
    const e = err as { status?: number; message?: string };
    if (e?.message && /already (active|activated)/i.test(e.message)) {
      await router.push('/login');
      return;
    }
    setErrors({ otp: e?.message ?? 'Activation failed' });
    otp.value = '';
  }
});

const resendCooldown = ref(0);
let resendTimer: ReturnType<typeof setInterval> | null = null;

function startCooldown() {
  resendCooldown.value = 30;
  if (resendTimer) clearInterval(resendTimer);
  resendTimer = setInterval(() => {
    resendCooldown.value -= 1;
    if (resendCooldown.value <= 0 && resendTimer) {
      clearInterval(resendTimer);
      resendTimer = null;
    }
  }, 1000);
}

onBeforeUnmount(() => {
  if (resendTimer) clearInterval(resendTimer);
});

async function onResend() {
  if (resendCooldown.value > 0) return;
  if (!email.value) {
    setErrors({ email: 'Enter your email first' });
    return;
  }
  try {
    await resend.mutateAsync({ type: 'REGISTER', email: email.value });
    startCooldown();
  } catch (err) {
    const e = err as { message?: string };
    setErrors({ otp: e?.message ?? 'Resend failed' });
  }
}
</script>

<template>
  <main class="activate">
    <h1>ACTIVATE</h1>
    <form novalidate class="activate__form" @submit.prevent="onSubmit">
      <BInput
        v-model="email"
        v-bind="emailAttrs"
        :error="errors.email"
        :readonly="emailLocked"
        label="Email"
        autocomplete="email"
      />
      <BInput
        v-model="otp"
        v-bind="otpAttrs"
        :error="errors.otp"
        label="Code"
        autocomplete="one-time-code"
        inputmode="numeric"
      />
      <BButton type="submit" variant="spot" :disabled="pending">
        {{ pending ? 'ACTIVATING…' : 'ACTIVATE' }}
      </BButton>
      <BButton type="button" variant="ghost" :disabled="resendCooldown > 0" @click="onResend">
        {{ resendCooldown > 0 ? `RESEND IN ${resendCooldown}s` : 'RESEND CODE' }}
      </BButton>
    </form>
  </main>
</template>

<style scoped>
.activate {
  max-width: 28rem;
  margin: 0 auto;
  padding: var(--space-6);
  font-family: var(--font-display);
}
.activate h1 {
  font-size: 2rem;
  margin-bottom: var(--space-6);
}
.activate__form {
  display: flex;
  flex-direction: column;
  gap: var(--space-3);
}

@media (max-width: 37.49rem) {
  .activate {
    padding: var(--space-6) var(--space-4);
  }
  .activate h1 {
    font-size: 1.75rem;
  }
}
</style>
