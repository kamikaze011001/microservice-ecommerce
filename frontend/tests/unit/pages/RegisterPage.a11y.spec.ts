// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import { setActivePinia, createPinia } from 'pinia';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { axe } from 'vitest-axe';
import { router } from '@/router';
import RegisterPage from '@/pages/RegisterPage.vue';

vi.mock('@/api/queries/auth', () => ({
  useRegisterMutation: () => ({ mutateAsync: vi.fn(), isPending: { value: false } }),
  useLoginMutation: vi.fn(),
  useLogout: () => () => {},
}));

beforeEach(async () => {
  setActivePinia(createPinia());
  router.push('/register');
  await router.isReady();
});

function mount() {
  return render(RegisterPage, {
    global: { plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]] },
  });
}

describe('RegisterPage — accessibility', () => {
  it('has no axe violations in its default state', async () => {
    const { container } = mount();
    expect(await axe(container)).toHaveNoViolations();
  });

  it('exposes exactly one <main> landmark and a level-1 heading', () => {
    const { container } = mount();
    expect(container.querySelectorAll('main')).toHaveLength(1);
    expect(screen.getByRole('heading', { level: 1 }).textContent).toMatch(/register/i);
  });

  it('labels every field and names the submit control (SR + keyboard)', async () => {
    const user = userEvent.setup();
    mount();
    expect(screen.getByLabelText(/username/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/email/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/^password/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/confirm password/i)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /register/i })).toBeInTheDocument();
    // Keyboard reachability: first Tab lands on the first field, no trap before it.
    await user.tab();
    expect(screen.getByLabelText(/username/i)).toHaveFocus();
  });
});
