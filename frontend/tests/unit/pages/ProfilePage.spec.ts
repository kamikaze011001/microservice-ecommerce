import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/vue';
import userEvent from '@testing-library/user-event';
import { setActivePinia, createPinia } from 'pinia';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import { router } from '@/router';
import ProfilePage from '@/pages/account/ProfilePage.vue';

// ── mutation spies ────────────────────────────────────────────────────────────
const updateProfileM = vi.fn();
const passwordM = vi.fn();
const presignM = vi.fn();
const attachM = vi.fn();

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
  useUpdateProfileMutation: () => ({
    mutateAsync: updateProfileM,
    isPending: { value: false },
  }),
  useChangePasswordMutation: () => ({
    mutateAsync: passwordM,
    isPending: { value: false },
  }),
  useAvatarPresignMutation: () => ({
    mutateAsync: presignM,
    isPending: { value: false },
  }),
  useAttachAvatarMutation: () => ({
    mutateAsync: attachM,
    isPending: { value: false },
  }),
}));

function mount() {
  return render(ProfilePage, {
    global: {
      plugins: [router, [VueQueryPlugin, { queryClient: new QueryClient() }]],
    },
  });
}

beforeEach(async () => {
  setActivePinia(createPinia());
  updateProfileM.mockReset();
  passwordM.mockReset();
  presignM.mockReset();
  attachM.mockReset();
  await router.push('/account/profile');
  await router.isReady();
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe('ProfilePage', () => {
  it('Test 1: profile form shows Zod error when name is cleared and blurred', async () => {
    mount();
    const nameInput = screen.getByLabelText(/NAME/i);
    // clear the pre-filled name and blur
    await userEvent.clear(nameInput);
    await userEvent.tab();
    await waitFor(() => expect(screen.getByText(/Name is required/i)).toBeInTheDocument());
  });

  it('Test 2: avatar happy path — presign → PUT → attach', async () => {
    presignM.mockResolvedValueOnce({
      upload_url: 'https://s3.example.com/upload',
      object_key: 'avatars/u1/abc.png',
      expires_at: '2099-01-01T00:00:00Z',
    });
    attachM.mockResolvedValueOnce({ avatar_url: 'https://s3.example.com/avatars/u1/abc.png' });

    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValue(new Response(null, { status: 200 }));

    mount();

    const fileInput = document.querySelector<HTMLInputElement>('input[type="file"]');
    expect(fileInput).not.toBeNull();

    const file = new File(['x'], 'a.png', { type: 'image/png' });
    await userEvent.upload(fileInput!, file);

    await waitFor(() => expect(presignM).toHaveBeenCalled());
    await waitFor(() =>
      expect(fetchSpy).toHaveBeenCalledWith(
        'https://s3.example.com/upload',
        expect.objectContaining({ method: 'PUT' }),
      ),
    );
    await waitFor(() => expect(attachM).toHaveBeenCalledWith({ object_key: 'avatars/u1/abc.png' }));
  });

  it('Test 3: password mismatch blocks submit and shows error', async () => {
    mount();
    const newPwdInput = screen.getByLabelText('NEW PASSWORD');
    const confirmInput = screen.getByLabelText('CONFIRM NEW PASSWORD');

    await userEvent.type(newPwdInput, 'abc12345');
    await userEvent.type(confirmInput, 'different');
    await userEvent.click(screen.getByRole('button', { name: /CHANGE PASSWORD/i }));

    await waitFor(() => expect(screen.getByText(/Passwords do not match/i)).toBeInTheDocument());
    expect(passwordM).not.toHaveBeenCalled();
  });
});
