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
    template: `<div style="padding:2rem">
      <p>A paragraph of body copy above the divider.</p>
      <BCropmarks v-bind="args" />
      <p>A second block below it — the crop marks sit in the margin between sections.</p>
    </div>`,
  }),
};
export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {};
