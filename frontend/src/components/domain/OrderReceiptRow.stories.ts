import type { Meta, StoryObj } from '@storybook/vue3-vite';
import OrderReceiptRow from './OrderReceiptRow.vue';
import type { OrderSummary } from '@/api/queries/orders';

const baseSummary: OrderSummary = {
  id: 'ord-a1b2c3d4-e5f6',
  status: 'COMPLETED',
  address: '221B Baker Street, London',
  phone_number: '+44 20 7946 0958',
  created_at: '2026-06-18T14:22:00Z',
  updated_at: '2026-06-18T14:30:00Z',
  total_amount: 90,
  item_count: 3,
  first_item_image_url: 'https://placehold.co/160x160',
};

const meta: Meta<typeof OrderReceiptRow> = {
  title: 'Patterns/OrderReceiptRow',
  component: OrderReceiptRow,
  tags: ['autodocs'],
  args: { summary: baseSummary },
};
export default meta;

type Story = StoryObj<typeof meta>;

export const Paid: Story = {};

export const Processing: Story = {
  args: { summary: { ...baseSummary, status: 'PROCESSING' } },
};

export const Canceled: Story = {
  args: { summary: { ...baseSummary, status: 'CANCELED' } },
};

export const NoImage: Story = {
  args: { summary: { ...baseSummary, first_item_image_url: null } },
};
