<script setup lang="ts">
import { isRef, computed, ref } from 'vue';
import { useForm } from 'vee-validate';
import { toTypedSchema } from '@vee-validate/zod';
import { useRoute, useRouter } from 'vue-router';
import { loginSchema } from '@/lib/zod-schemas';
import { useLoginMutation } from '@/api/queries/auth';
import { BButton, BInput } from '@/components/primitives';
import { ApiError, classify } from '@/api/error';

const route = useRoute();
const router = useRouter();
const mutation = useLoginMutation();
const login = mutation.mutateAsync;
const pending = computed(() =>
  isRef(mutation.isPending)
    ? mutation.isPending.value
    : !!(mutation.isPending as { value?: boolean })?.value,
);

const { handleSubmit, errors, defineField, setErrors } = useForm({
  validationSchema: toTypedSchema(loginSchema),
  initialValues: { username: '', password: '' },
});

const [usernameModel, usernameAttrs] = defineField('username');
const [passwordModel, passwordAttrs] = defineField('password');
// BInput requires string (not string | undefined); coerce undefined → ''
const username = computed({
  get: () => usernameModel.value ?? '',
  set: (v) => {
    usernameModel.value = v;
  },
});
const password = computed({
  get: () => passwordModel.value ?? '',
  set: (v) => {
    passwordModel.value = v;
  },
});

function safeNext(raw: unknown): string {
  if (typeof raw !== 'string') return '/';
  return raw.startsWith('/') ? raw : '/';
}

const notActivated = ref(false);

const onSubmit = handleSubmit(async (values) => {
  notActivated.value = false;
  try {
    await login(values);
    await router.push(safeNext(route.query.next));
  } catch (err) {
    if (err instanceof ApiError && classify(err) === 'not-activated') {
      notActivated.value = true;
      return;
    }
    const e = err as { code?: string; message?: string };
    if (e?.code === 'INVALID_CREDENTIALS') {
      setErrors({ password: 'Wrong email or password' });
    } else if (e?.message) {
      setErrors({ password: e.message });
    }
  }
});
</script>

<template>
  <main class="login">
    <h1>LOG IN</h1>
    <form novalidate class="login__form" @submit.prevent="onSubmit">
      <BInput
        v-model="username"
        v-bind="usernameAttrs"
        :error="errors.username"
        label="Username"
        autocomplete="username"
      />
      <BInput
        v-model="password"
        v-bind="passwordAttrs"
        :error="errors.password"
        type="password"
        label="Password"
        autocomplete="current-password"
      />
      <BButton type="submit" variant="spot" :disabled="pending">
        {{ pending ? 'STAMPING…' : 'LOG IN' }}
      </BButton>
      <p class="login__alt">No account? <RouterLink to="/register">REGISTER</RouterLink></p>
      <p v-if="notActivated" class="login__alt">
        Account not activated.
        <RouterLink to="/activate">Activate it →</RouterLink>
      </p>
    </form>
  </main>
</template>

<style scoped>
.login {
  max-width: 28rem;
  margin: 0 auto;
  padding: var(--space-6);
  font-family: var(--font-display);
}
.login h1 {
  font-size: 2rem;
  margin-bottom: var(--space-6);
}
.login__form {
  display: flex;
  flex-direction: column;
  gap: var(--space-3);
}
.login__alt {
  font-family: var(--font-body);
  font-size: 0.875rem;
  color: var(--muted-ink);
}
.login__alt a {
  color: var(--spot);
  text-decoration: underline;
}

@media (max-width: 37.49rem) {
  .login {
    padding: var(--space-6) var(--space-4);
  }
  .login h1 {
    font-size: 1.75rem;
  }
}
</style>
