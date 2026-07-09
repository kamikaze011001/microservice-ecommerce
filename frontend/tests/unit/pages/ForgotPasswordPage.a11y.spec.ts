// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import { setActivePinia, createPinia } from 'pinia';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { axe } from 'vitest-axe';
import { router } from '@/router';
import ForgotPasswordPage from '@/pages/ForgotPasswordPage.vue';

// Top-level page: it owns its own <main> + <h1>, so the standard document-level
// rubric applies (single <main>, level-1 heading) — no LAYOUT_OWNED_RULES carve-outs.
// The primary loaded state is step 1 (enter email); the page starts there with no
// route params, so no mutation needs to resolve to render the guarded surface.
vi.mock('@/api/queries/auth', () => ({
  useForgotPasswordMutation: () => ({ mutateAsync: vi.fn(), isPending: { value: false } }),
  useVerifyForgotOtpMutation: () => ({ mutateAsync: vi.fn(), isPending: { value: false } }),
  useResendOtpMutation: () => ({ mutateAsync: vi.fn(), isPending: { value: false } }),
  useResetPasswordMutation: () => ({ mutateAsync: vi.fn(), isPending: { value: false } }),
}));

beforeEach(async () => {
  setActivePinia(createPinia());
  await router.push('/forgot-password');
  await router.isReady();
});

function mount() {
  return render(ForgotPasswordPage, {
    global: { plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]] },
  });
}

describe('ForgotPasswordPage — accessibility', () => {
  it('has no axe violations in its default (step 1 — enter email) state', async () => {
    const { container } = mount();
    expect(await axe(container)).toHaveNoViolations();
  });

  it('exposes exactly one <main> landmark and a level-1 heading', () => {
    const { container } = mount();
    expect(container.querySelectorAll('main')).toHaveLength(1);
    expect(screen.getByRole('heading', { level: 1 }).textContent).toMatch(/reset password/i);
  });

  it('labels the email field, names the submit action, and links back to log in (SR + keyboard)', async () => {
    const user = userEvent.setup();
    mount();
    expect(screen.getByLabelText(/email/i)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /send code/i })).toBeInTheDocument();
    // Recovery escape hatch is a named link, not a button, so SR users can find "back to log in".
    expect(screen.getByRole('link', { name: /back to log in/i })).toHaveAttribute('href', '/login');
    // Keyboard reachability: first Tab lands on the email field, no trap before it.
    await user.tab();
    expect(screen.getByLabelText(/email/i)).toHaveFocus();
  });
});
