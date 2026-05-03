<script setup lang="ts">
import { isRef, computed } from 'vue';
import { useForm } from 'vee-validate';
import { toTypedSchema } from '@vee-validate/zod';
import { useRouter } from 'vue-router';
import { registerSchema } from '@/lib/zod-schemas';
import { useRegisterMutation } from '@/api/queries/auth';
import { BButton, BInput } from '@/components/primitives';

const router = useRouter();
const mutation = useRegisterMutation();
const doRegister = mutation.mutateAsync;
const pending = computed(() =>
  isRef(mutation.isPending)
    ? mutation.isPending.value
    : !!(mutation.isPending as { value?: boolean })?.value,
);

const { handleSubmit, errors, defineField, setErrors } = useForm({
  validationSchema: toTypedSchema(registerSchema),
  initialValues: { username: '', email: '', password: '', confirmPassword: '' },
});

const [usernameModel, usernameAttrs] = defineField('username');
const [emailModel, emailAttrs] = defineField('email');
const [passwordModel, passwordAttrs] = defineField('password');
const [confirmPasswordModel, confirmPasswordAttrs] = defineField('confirmPassword');

// BInput requires string (not string | undefined); coerce undefined → ''
const username = computed({
  get: () => usernameModel.value ?? '',
  set: (v) => {
    usernameModel.value = v;
  },
});
const email = computed({
  get: () => emailModel.value ?? '',
  set: (v) => {
    emailModel.value = v;
  },
});
const password = computed({
  get: () => passwordModel.value ?? '',
  set: (v) => {
    passwordModel.value = v;
  },
});
const confirmPassword = computed({
  get: () => confirmPasswordModel.value ?? '',
  set: (v) => {
    confirmPasswordModel.value = v;
  },
});

const onSubmit = handleSubmit(async (values) => {
  try {
    await doRegister(values);
    await router.push({ path: '/activate', query: { email: values.email } });
  } catch (err) {
    const e = err as { code?: string; message?: string };
    if (e?.code === 'EMAIL_TAKEN') {
      setErrors({ email: 'Email already in use' });
    } else if (e?.message) {
      setErrors({ email: e.message });
    }
  }
});
</script>

<template>
  <main class="register">
    <h1>REGISTER</h1>
    <form novalidate class="register__form" @submit.prevent="onSubmit">
      <BInput
        v-model="username"
        v-bind="usernameAttrs"
        :error="errors.username"
        label="Username"
        autocomplete="username"
      />
      <BInput
        v-model="email"
        v-bind="emailAttrs"
        :error="errors.email"
        label="Email"
        autocomplete="email"
      />
      <BInput
        v-model="password"
        v-bind="passwordAttrs"
        :error="errors.password"
        type="password"
        label="Password"
        autocomplete="new-password"
      />
      <BInput
        v-model="confirmPassword"
        v-bind="confirmPasswordAttrs"
        :error="errors.confirmPassword"
        type="password"
        label="Confirm Password"
        autocomplete="new-password"
      />
      <BButton type="submit" variant="spot" :disabled="pending">
        {{ pending ? 'REGISTERING…' : 'REGISTER' }}
      </BButton>
      <p class="register__alt">
        Already have an account? <RouterLink to="/login">LOG IN</RouterLink>
      </p>
      <p class="register__alt">
        Already registered?
        <RouterLink to="/activate">Activate your account →</RouterLink>
      </p>
    </form>
  </main>
</template>

<style scoped>
.register {
  max-width: 28rem;
  margin: 0 auto;
  padding: var(--space-6);
  font-family: var(--font-display);
}
.register h1 {
  font-size: 2rem;
  margin-bottom: var(--space-6);
}
.register__form {
  display: flex;
  flex-direction: column;
  gap: var(--space-3);
}
.register__alt {
  font-family: var(--font-body);
  font-size: 0.875rem;
  color: var(--muted-ink);
}
.register__alt a {
  color: var(--spot-ink);
  text-decoration: underline;
}

@media (max-width: 37.49rem) {
  .register {
    padding: var(--space-6) var(--space-4);
  }
  .register h1 {
    font-size: 1.75rem;
  }
}
</style>
