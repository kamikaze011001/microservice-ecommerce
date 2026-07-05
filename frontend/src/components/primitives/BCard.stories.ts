import type { Meta, StoryObj } from '@storybook/vue3-vite';
import BCard from './BCard.vue';

const meta: Meta<typeof BCard> = {
  title: 'Primitives/BCard',
  component: BCard,
  tags: ['autodocs'],
  argTypes: {
    rotate: { control: { type: 'number', min: -2, max: 2, step: 0.5 } },
    hoverMisregister: { control: 'boolean' },
    as: { control: 'text' },
  },
  args: { hoverMisregister: true, rotate: 0.5 },
  render: (args) => ({
    components: { BCard },
    setup: () => ({ args }),
    template: `<BCard v-bind="args" style="max-width:20rem;padding:var(--space-6)"><h3>Riso Print Nº01</h3><p>Hover me — the title misregisters.</p></BCard>`,
  }),
};
export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {};
export const Straight: Story = { args: { rotate: 0, hoverMisregister: false } };
