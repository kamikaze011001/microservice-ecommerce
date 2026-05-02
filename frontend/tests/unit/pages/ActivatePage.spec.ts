import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/vue';
import { flushPromises } from '@vue/test-utils';
import userEvent from '@testing-library/user-event';
import { setActivePinia, createPinia } from 'pinia';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { router } from '@/router';
import ActivatePage from '@/pages/ActivatePage.vue';

const activateMutateAsync = vi.fn();
const resendMutateAsync = vi.fn();

vi.mock('@/api/queries/auth', () => ({
  useActivateMutation: () => ({ mutateAsync: activateMutateAsync, isPending: { value: false } }),
  useResendOtpMutation: () => ({ mutateAsync: resendMutateAsync, isPending: { value: false } }),
  useLoginMutation: vi.fn(),
  useRegisterMutation: vi.fn(),
  useLogout: () => () => {},
}));

beforeEach(async () => {
  vi.useFakeTimers();
  setActivePinia(createPinia());
  activateMutateAsync.mockReset();
  resendMutateAsync.mockReset();
  await router.push({ path: '/activate', query: { email: 'son@example.com' } });
  await router.isReady();
});

afterEach(() => {
  vi.useRealTimers();
});

const user = userEvent.setup({ advanceTimers: (ms) => vi.advanceTimersByTime(ms) });

function mount() {
  return render(ActivatePage, {
    global: {
      plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]],
    },
  });
}

describe('ActivatePage', () => {
  it('happy path: submits email + otp and navigates to /login', async () => {
    activateMutateAsync.mockResolvedValueOnce(undefined);
    mount();
    expect((screen.getByLabelText(/email/i) as HTMLInputElement).value).toBe('son@example.com');
    await user.type(screen.getByLabelText(/code/i), '123456');
    await user.click(screen.getByRole('button', { name: /activate/i }));
    vi.advanceTimersByTime(10);
    await flushPromises();
    await waitFor(() =>
      expect(activateMutateAsync).toHaveBeenCalledWith({ email: 'son@example.com', otp: '123456' }),
    );
    await waitFor(() => expect(router.currentRoute.value.path).toBe('/login'));
  });
});
