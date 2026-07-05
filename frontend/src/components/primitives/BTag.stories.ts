import type { Meta, StoryObj } from '@storybook/vue3-vite';
import BTag from './BTag.vue';

const meta: Meta<typeof BTag> = {
  title: 'Primitives/BTag',
  component: BTag,
  tags: ['autodocs'],
  argTypes: {
    tone: { control: 'select', options: ['ink', 'spot', 'paper'] },
    rotate: { control: { type: 'number', min: -10, max: 10 } },
  },
  args: { tone: 'ink' },
  render: (args) => ({
    components: { BTag },
    setup: () => ({ args }),
    template: `<BTag v-bind="args">SKU-0042</BTag>`,
  }),
};
export default meta;
type Story = StoryObj<typeof meta>;

export const Ink: Story = {};
export const Spot: Story = { args: { tone: 'spot' } };
export const Paper: Story = { args: { tone: 'paper' } };
