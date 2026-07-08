import type { Meta, StoryObj } from '@storybook/vue3-vite';
import BPageButton from './BPageButton.vue';

const meta: Meta<typeof BPageButton> = {
  title: 'Primitives/BPageButton',
  component: BPageButton,
  tags: ['autodocs'],
  argTypes: {
    active: { control: 'boolean' },
  },
  args: { active: false },
  render: (args) => ({
    components: { BPageButton },
    setup: () => ({ args }),
    template: `<BPageButton v-bind="args">3</BPageButton>`,
  }),
};
export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {};
export const Active: Story = { args: { active: true } };
