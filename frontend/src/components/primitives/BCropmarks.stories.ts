import type { Meta, StoryObj } from '@storybook/vue3-vite';
import BCropmarks from './BCropmarks.vue';

const meta: Meta<typeof BCropmarks> = {
  title: 'Primitives/BCropmarks',
  component: BCropmarks,
  tags: ['autodocs'],
  argTypes: { inset: { control: 'text' } },
  args: { inset: '1rem' },
  render: (args) => ({
    components: { BCropmarks },
    setup: () => ({ args }),
    template: `<div style="padding:2rem"><BCropmarks v-bind="args"><div style="padding:var(--space-6)">Content framed by crop marks</div></BCropmarks></div>`,
  }),
};
export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {};
