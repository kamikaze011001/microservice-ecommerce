import type { Meta, StoryObj } from '@storybook/vue3-vite';
import CartSummary from './CartSummary.vue';
import type { CartItem } from '@/api/queries/cart';

const items: CartItem[] = [
  {
    shopping_cart_item_id: 'sci-001',
    product_id: 'prod-042',
    name: 'FIELD NOTES — RULED PRESS JACKET',
    image_url: 'https://placehold.co/240x240',
    unit_price: 28,
    quantity: 2,
    available_stock: 12,
  },
  {
    shopping_cart_item_id: 'sci-002',
    product_id: 'prod-091',
    name: 'LETTERPRESS TOTE BAG',
    image_url: 'https://placehold.co/240x240',
    unit_price: 34,
    quantity: 1,
    available_stock: 6,
  },
];

const meta: Meta<typeof CartSummary> = {
  title: 'Patterns/CartSummary',
  component: CartSummary,
  tags: ['autodocs'],
  args: { items },
};
export default meta;

type Story = StoryObj<typeof meta>;

export const Default: Story = {};

export const Empty: Story = { args: { items: [] } };
