import type { Meta, StoryObj } from '@storybook/vue3-vite';
import CartLineItem from './CartLineItem.vue';
import type { CartItem } from '@/api/queries/cart';

const baseItem: CartItem = {
  shopping_cart_item_id: 'sci-001',
  product_id: 'prod-042',
  name: 'FIELD NOTES — RULED PRESS JACKET',
  image_url: 'https://placehold.co/240x240',
  unit_price: 28,
  quantity: 2,
  available_stock: 12,
};

const meta: Meta<typeof CartLineItem> = {
  title: 'Patterns/CartLineItem',
  component: CartLineItem,
  tags: ['autodocs'],
  args: { item: baseItem },
};
export default meta;

type Story = StoryObj<typeof meta>;

export const Default: Story = {};

export const LowStock: Story = {
  args: {
    item: { ...baseItem, quantity: 5, available_stock: 3 },
  },
};

export const NoImage: Story = {
  args: {
    item: { ...baseItem, image_url: '', name: 'LETTERPRESS TOTE BAG' },
  },
};

export const PendingQuantity: Story = {
  args: {
    item: baseItem,
    pendingQuantity: 4,
  },
};
