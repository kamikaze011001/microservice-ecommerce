import type { Meta, StoryObj } from '@storybook/vue3-vite';
import OrderItemRow from './OrderItemRow.vue';
import type { OrderDetailItem } from '@/api/queries/orders';

const baseItem: OrderDetailItem = {
  id: 'oi-001',
  product_id: 'prod-042',
  product_name: 'FIELD NOTES — RULED PRESS JACKET',
  image_url: 'https://placehold.co/160x160',
  price: 28,
  quantity: 2,
};

const meta: Meta<typeof OrderItemRow> = {
  title: 'Patterns/OrderItemRow',
  component: OrderItemRow,
  tags: ['autodocs'],
  args: { item: baseItem, index: 1 },
};
export default meta;

type Story = StoryObj<typeof meta>;

export const Default: Story = {};

export const NoImage: Story = {
  args: { item: { ...baseItem, image_url: null }, index: 2 },
};

export const ProductUnavailable: Story = {
  args: {
    item: { ...baseItem, product_name: null, image_url: null },
    index: 3,
  },
};
