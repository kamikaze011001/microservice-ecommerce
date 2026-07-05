import type { Meta, StoryObj } from '@storybook/vue3-vite';
import BStamp from './BStamp.vue';

const meta: Meta<typeof BStamp> = {
  title: 'Primitives/BStamp',
  component: BStamp,
  tags: ['autodocs'],
  argTypes: {
    tone: { control: 'select', options: ['red', 'ink', 'spot'] },
    size: { control: 'select', options: ['sm', 'md', 'lg'] },
    rotate: { control: { type: 'number', min: -15, max: 15 } },
  },
  args: { tone: 'red', size: 'md', rotate: -6 },
  render: (args) => ({
    components: { BStamp },
    setup: () => ({ args }),
    template: `<BStamp v-bind="args">PAID</BStamp>`,
  }),
};
export default meta;
type Story = StoryObj<typeof meta>;

export const Paid: Story = {};
export const Processing: Story = {
  args: { tone: 'ink' },
  render: (args) => ({
    components: { BStamp },
    setup: () => ({ args }),
    template: `<BStamp v-bind="args">PROCESSING</BStamp>`,
  }),
};
export const Canceled: Story = {
  args: { tone: 'red', rotate: 8 },
  render: (args) => ({
    components: { BStamp },
    setup: () => ({ args }),
    template: `<BStamp v-bind="args">CANCELED</BStamp>`,
  }),
};
