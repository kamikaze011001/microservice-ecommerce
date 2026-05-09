<script setup lang="ts">
import { computed, ref } from 'vue';
import { useForm } from 'vee-validate';
import { toTypedSchema } from '@vee-validate/zod';
import { useRouter } from 'vue-router';
import { forgotPasswordSchema } from '@/lib/zod-schemas';
import { useForgotPasswordMutation } from '@/api/queries/auth';
import { BButton, BInput } from '@/components/primitives';

const router = useRouter();
void router; // wired in later steps

const step = ref<1 | 2 | 3>(1);
const email = ref('');
const resetPasswordKey = ref('');
void resetPasswordKey.value; // populated in step 2

const stepLabel = computed(() =>
  step.value === 1 ? 'ENTER EMAIL' : step.value === 2 ? 'ENTER CODE' : 'NEW PASSWORD',
);

// ── Step 1: email ────────────────────────────────────────────────────────
const forgot = useForgotPasswordMutation();
const step1 = useForm({
  validationSchema: toTypedSchema(forgotPasswordSchema),
  initialValues: { email: '' },
});
const [emailModel, emailAttrs] = step1.defineField('email');
const emailField = computed({
  get: () => emailModel.value ?? '',
  set: (v) => {
    emailModel.value = v;
  },
});

const onSubmitEmail = step1.handleSubmit(async (values) => {
  try {
    await forgot.mutateAsync({ email: values.email });
    email.value = values.email;
    step.value = 2;
  } catch (err) {
    const e = err as { message?: string };
    step1.setErrors({ email: e?.message ?? 'Could not send the code' });
  }
});

const pending1 = computed(() => forgot.isPending?.value === true);
</script>

<template>
  <main class="forgot">
    <h1>RESET PASSWORD</h1>
    <p class="forgot__progress">STEP {{ step }} OF 3 · {{ stepLabel }}</p>

    <form v-if="step === 1" novalidate class="forgot__form" @submit.prevent="onSubmitEmail">
      <BInput
        v-model="emailField"
        v-bind="emailAttrs"
        :error="step1.errors.value.email"
        label="Email"
        autocomplete="email"
      />
      <BButton type="submit" variant="spot" :disabled="pending1">
        {{ pending1 ? 'SENDING…' : 'SEND CODE' }}
      </BButton>
    </form>

    <p class="forgot__alt">Remember it? <RouterLink to="/login">BACK TO LOG IN</RouterLink></p>
  </main>
</template>

<style scoped>
.forgot {
  max-width: 28rem;
  margin: 0 auto;
  padding: var(--space-6);
  font-family: var(--font-display);
}
.forgot h1 {
  font-size: 2rem;
  margin-bottom: var(--space-4);
}
.forgot__progress {
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  color: var(--muted-ink);
  margin-bottom: var(--space-6);
  text-transform: uppercase;
  letter-spacing: 0.08em;
}
.forgot__form {
  display: flex;
  flex-direction: column;
  gap: var(--space-3);
}
.forgot__alt {
  font-family: var(--font-body);
  font-size: 0.875rem;
  color: var(--muted-ink);
  margin-top: var(--space-4);
}
.forgot__alt a {
  color: var(--spot-ink);
  text-decoration: underline;
}

@media (max-width: 37.49rem) {
  .forgot {
    padding: var(--space-6) var(--space-4);
  }
  .forgot h1 {
    font-size: 1.75rem;
  }
}
</style>
