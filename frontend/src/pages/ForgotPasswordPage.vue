<script setup lang="ts">
import { computed, onBeforeUnmount, ref } from 'vue';
import { useForm } from 'vee-validate';
import { toTypedSchema } from '@vee-validate/zod';
import { useRouter } from 'vue-router';
import { z } from 'zod';
import { forgotPasswordSchema } from '@/lib/zod-schemas';
import {
  useForgotPasswordMutation,
  useVerifyForgotOtpMutation,
  useResendOtpMutation,
} from '@/api/queries/auth';

const otpOnlySchema = z.object({
  otp: z.string().regex(/^\d{4,8}$/, 'Enter the code from your email'),
});
import { BButton, BInput } from '@/components/primitives';

const router = useRouter();
void router; // wired in later steps

const step = ref<1 | 2 | 3>(1);
const email = ref('');
const resetPasswordKey = ref('');

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

// ── Step 2: OTP verify ───────────────────────────────────────────────────
const verify = useVerifyForgotOtpMutation();
const resend = useResendOtpMutation();

const step2 = useForm({
  validationSchema: toTypedSchema(otpOnlySchema),
  initialValues: { otp: '' },
});
const [otpModel, otpAttrs] = step2.defineField('otp');
const otpField = computed({
  get: () => otpModel.value ?? '',
  set: (v) => {
    otpModel.value = v;
  },
});

const onSubmitOtp = step2.handleSubmit(async (values) => {
  try {
    const data = await verify.mutateAsync({ email: email.value, otp: values.otp });
    resetPasswordKey.value = data.reset_password_key;
    step.value = 3;
  } catch (err) {
    const e = err as { message?: string };
    step2.setErrors({ otp: e?.message ?? 'Invalid or expired code' });
    otpField.value = '';
  }
});

const pending2 = computed(() => verify.isPending?.value === true);

const resendCooldown = ref(0);
let resendTimer: ReturnType<typeof setInterval> | undefined;

function startCooldown() {
  resendCooldown.value = 30;
  resendTimer = setInterval(() => {
    resendCooldown.value -= 1;
    if (resendCooldown.value <= 0) {
      clearInterval(resendTimer);
      resendTimer = undefined;
    }
  }, 1000);
}

onBeforeUnmount(() => {
  if (resendTimer) clearInterval(resendTimer);
});

async function onResend() {
  if (resendCooldown.value > 0) return;
  if (!email.value) return;
  try {
    await resend.mutateAsync({ type: 'forgot_password', email: email.value });
    startCooldown();
  } catch (err) {
    const e = err as { message?: string };
    step2.setErrors({ otp: e?.message ?? 'Resend failed' });
  }
}
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

    <form v-if="step === 2" novalidate class="forgot__form" @submit.prevent="onSubmitOtp">
      <p class="forgot__hint">
        We sent a code to <strong>{{ email }}</strong
        >.
      </p>
      <BInput
        v-model="otpField"
        v-bind="otpAttrs"
        :error="step2.errors.value.otp"
        label="Code"
        autocomplete="one-time-code"
        inputmode="numeric"
      />
      <BButton type="submit" variant="spot" :disabled="pending2">
        {{ pending2 ? 'VERIFYING…' : 'VERIFY' }}
      </BButton>
      <BButton type="button" variant="ghost" :disabled="resendCooldown > 0" @click="onResend">
        {{ resendCooldown > 0 ? `RESEND IN ${resendCooldown}s` : 'RESEND CODE' }}
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
.forgot__hint {
  font-family: var(--font-body);
  font-size: 0.875rem;
  color: var(--muted-ink);
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
