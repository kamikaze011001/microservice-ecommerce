// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import { setActivePinia, createPinia } from 'pinia';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { axe } from 'vitest-axe';
import { router } from '@/router';
import ProfilePage from '@/pages/account/ProfilePage.vue';

vi.mock('@/api/queries/profile', () => ({
  useProfileQuery: () => ({
    data: {
      value: {
        id: 'u1',
        name: 'Test User',
        email: 'test@example.com',
        gender: null,
        address: null,
        avatar_url: null,
      },
    },
    isLoading: { value: false },
    isError: { value: false },
    error: { value: null },
  }),
  useUpdateProfileMutation: () => ({ mutateAsync: vi.fn(), isPending: { value: false } }),
  useChangePasswordMutation: () => ({ mutateAsync: vi.fn(), isPending: { value: false } }),
  useAvatarPresignMutation: () => ({ mutateAsync: vi.fn(), isPending: { value: false } }),
  useAttachAvatarMutation: () => ({ mutateAsync: vi.fn(), isPending: { value: false } }),
}));
vi.mock('@/api/queries/auth', () => ({
  useLogoutAllMutation: () => ({ mutate: vi.fn(), isPending: { value: false } }),
}));

// ProfilePage is a layout-embedded fragment: AccountLayout owns the page's single
// <main> landmark and (should own) the page-level <h1>. This per-page guard covers
// the fragment's OWN responsibilities — labelled controls, ARIA, and per-section
// region landmarks — so the two document-level best-practice rules that belong to
// the layout are scoped out here. (Follow-up: AccountLayout's masthead is a <p>,
// not an <h1> — a real gap to fix in a layout-level a11y pass.)
const LAYOUT_OWNED_RULES = {
  'landmark-one-main': { enabled: false },
  'page-has-heading-one': { enabled: false },
} as const;

beforeEach(async () => {
  setActivePinia(createPinia());
  await router.push('/account/profile');
  await router.isReady();
});

function mount() {
  return render(ProfilePage, {
    global: { plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]] },
  });
}

describe('ProfilePage — accessibility', () => {
  it('has no axe violations across its three forms + sessions section', async () => {
    const { container } = mount();
    expect(await axe(container, { rules: LAYOUT_OWNED_RULES })).toHaveNoViolations();
  });

  it('wraps every section in a named region landmark (incl. Sessions)', () => {
    mount();
    const regions = screen.getAllByRole('region');
    const names = regions.map((r) => r.getAttribute('aria-label'));
    expect(names).toEqual(
      expect.arrayContaining(['Avatar', 'Profile details', 'Change password', 'Sessions']),
    );
  });

  it('labels every form control and names every action (SR + keyboard)', async () => {
    const user = userEvent.setup();
    mount();
    // COLOPHON (profile) fields
    expect(screen.getByLabelText(/^name/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/gender/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/email/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/address/i)).toBeInTheDocument();
    // CREDENTIALS (password) fields
    expect(screen.getByLabelText('CURRENT PASSWORD')).toBeInTheDocument();
    expect(screen.getByLabelText('NEW PASSWORD')).toBeInTheDocument();
    expect(screen.getByLabelText('CONFIRM NEW PASSWORD')).toBeInTheDocument();
    // Named actions across sections
    expect(screen.getByLabelText(/upload avatar/i)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /save colophon/i })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /change password/i })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /log out all devices/i })).toBeInTheDocument();
    // Keyboard reachability: BFileButton keeps the real <input type=file> at tabindex=-1
    // and exposes a visible "CHANGE PHOTO" button as the operable proxy — so the first
    // Tab lands on that button (the correct keyboard target), not the hidden input.
    await user.tab();
    expect(screen.getByRole('button', { name: /change photo/i })).toHaveFocus();
  });
});
