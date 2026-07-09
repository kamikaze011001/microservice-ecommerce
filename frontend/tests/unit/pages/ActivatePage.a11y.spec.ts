// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import { setActivePinia, createPinia } from 'pinia';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { axe } from 'vitest-axe';
import { router } from '@/router';
import ActivatePage from '@/pages/ActivatePage.vue';

// Top-level page: it owns its own <main> + <h1>, so the standard document-level
// rubric applies (single <main>, level-1 heading) — no LAYOUT_OWNED_RULES carve-outs.
vi.mock('@/api/queries/auth', () => ({
  useActivateMutation: () => ({ mutateAsync: vi.fn(), isPending: { value: false } }),
  useResendOtpMutation: () => ({ mutateAsync: vi.fn(), isPending: { value: false } }),
}));

beforeEach(async () => {
  setActivePinia(createPinia());
  // Bare /activate (no ?email=) so the email field is editable — the first tab stop.
  await router.push('/activate');
  await router.isReady();
});

function mount() {
  return render(ActivatePage, {
    global: { plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]] },
  });
}

describe('ActivatePage — accessibility', () => {
  it('has no axe violations in its default (activation form) state', async () => {
    const { container } = mount();
    expect(await axe(container)).toHaveNoViolations();
  });

  it('exposes exactly one <main> landmark and a level-1 heading', () => {
    const { container } = mount();
    expect(container.querySelectorAll('main')).toHaveLength(1);
    expect(screen.getByRole('heading', { level: 1 }).textContent).toMatch(/activate/i);
  });

  it('labels both fields and names both actions (SR + keyboard)', async () => {
    const user = userEvent.setup();
    mount();
    expect(screen.getByLabelText(/email/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/code/i)).toBeInTheDocument();
    // Submit + resend are both reachable by accessible name (button role, not the h1).
    expect(screen.getByRole('button', { name: /^activate/i })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /resend code/i })).toBeInTheDocument();
    // Keyboard reachability: first Tab lands on the email field, no trap before it.
    await user.tab();
    expect(screen.getByLabelText(/email/i)).toHaveFocus();
  });
});
