import type { Meta, StoryObj } from '@storybook/vue3-vite';
import OrderStatusStamp from './OrderStatusStamp.vue';

const meta: Meta<typeof OrderStatusStamp> = {
  title: 'Patterns/OrderStatusStamp',
  component: OrderStatusStamp,
  tags: ['autodocs'],
  argTypes: {
    status: {
      control: 'select',
      options: ['PROCESSING', 'COMPLETED', 'CANCELED', 'FAILED', 'REFUNDED'],
    },
  },
  args: { status: 'COMPLETED' },
};
export default meta;

type Story = StoryObj<typeof meta>;

export const Paid: Story = { args: { status: 'COMPLETED' } };
export const Processing: Story = { args: { status: 'PROCESSING' } };
export const Canceled: Story = { args: { status: 'CANCELED' } };
export const Failed: Story = { args: { status: 'FAILED' } };
export const Refunded: Story = { args: { status: 'REFUNDED' } };
