import type { Meta, StoryObj } from '@storybook/vue3-vite';
import BIconButton from './BIconButton.vue';

const meta: Meta<typeof BIconButton> = {
  title: 'Primitives/BIconButton',
  component: BIconButton,
  tags: ['autodocs'],
  argTypes: {
    disabled: { control: 'boolean' },
    type: { control: 'select', options: ['button', 'submit', 'reset'] },
  },
  args: { disabled: false, type: 'button' },
  render: (args) => ({
    components: { BIconButton },
    setup: () => ({ args }),
    // Icon buttons have no text label — always give them an accessible name.
    template: `
      <BIconButton v-bind="args" aria-label="Close">
        <svg width="20" height="20" viewBox="0 0 20 20" aria-hidden="true">
          <path d="M4 4 L16 16 M16 4 L4 16" stroke="currentColor" stroke-width="2" fill="none" />
        </svg>
      </BIconButton>
    `,
  }),
};
export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {};
export const Disabled: Story = { args: { disabled: true } };
