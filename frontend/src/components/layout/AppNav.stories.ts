import type { Meta, StoryObj } from '@storybook/vue3-vite';
import { useQueryClient } from '@tanstack/vue-query';
import AppNav from './AppNav.vue';
import { useAuthStore } from '@/stores/auth';
import type { ProfileData } from '@/api/queries/profile';
import type { CartResponse } from '@/api/queries/cart';

const meta: Meta<typeof AppNav> = {
  title: 'Patterns/AppNav',
  component: AppNav,
  tags: ['autodocs'],
};
export default meta;

type Story = StoryObj<typeof meta>;

// Guest: isLoggedIn stays false, so the profile/cart queries (`enabled: isLoggedIn`)
// never execute — no live network. This is the required baseline story.
export const Guest: Story = {
  render: () => ({
    components: { AppNav },
    setup() {
      useAuthStore().clear();
    },
    template: `<AppNav />`,
  }),
};

// SignedIn: isLoggedIn is true, so the profile/cart queries become enabled. We
// pre-seed the shared storybookQueryClient cache for those exact query keys and
// mark them fresh forever (`staleTime: Infinity`) so `useQuery` resolves from
// cache on mount instead of firing a real fetch.
const profileFixture: ProfileData = {
  id: 'user-001',
  name: 'Dana Voss',
  email: 'dana.voss@example.com',
  gender: 'OTHER',
  address: '221B Baker Street, London',
  avatar_url: null,
};

const cartFixture: CartResponse = {
  shopping_cart_id: 'cart-001',
  user_id: 'user-001',
  items: [
    {
      shopping_cart_item_id: 'sci-001',
      product_id: 'prod-042',
      name: 'FIELD NOTES — RULED PRESS JACKET',
      image_url: 'https://placehold.co/240x240',
      unit_price: 28,
      quantity: 2,
      available_stock: 12,
    },
  ],
};

export const SignedIn: Story = {
  render: () => ({
    components: { AppNav },
    setup() {
      useAuthStore().login({
        accessToken: 'story-access-token',
        refreshToken: 'story-refresh-token',
      });

      // Same QueryClient the app-level VueQueryPlugin installed (preview.ts) —
      // retrieved via the composable rather than importing preview.ts directly,
      // since that file lives outside tsconfig.app.json's `include`.
      const qc = useQueryClient();
      qc.setQueryDefaults(['profile'], { staleTime: Infinity, retry: false });
      qc.setQueryDefaults(['cart'], { staleTime: Infinity, retry: false });
      qc.setQueryData(['profile'], profileFixture);
      qc.setQueryData(['cart'], cartFixture);
    },
    template: `<AppNav />`,
  }),
};
