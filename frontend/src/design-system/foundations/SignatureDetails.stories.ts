import type { Meta, StoryObj } from '@storybook/vue3-vite';
import BCard from '../../components/primitives/BCard.vue';

const meta: Meta<typeof BCard> = {
  title: 'Foundations/Signature Details/Demos',
  component: BCard,
  tags: ['autodocs'],
  args: { hoverMisregister: false, rotate: 0 },
};
export default meta;
type Story = StoryObj<typeof meta>;

export const HoverMisregister: Story = {
  args: { hoverMisregister: true, rotate: 0 },
  render: (args) => ({
    components: { BCard },
    setup: () => ({ args }),
    template: `<BCard v-bind="args" style="max-width:20rem;padding:var(--space-6)"><h3>Riso Print Nº01</h3><p>Hover this card — the heading misregisters, like a two-pass print slightly out of alignment.</p></BCard>`,
  }),
};

export const StickerRotation: Story = {
  render: () => ({
    components: { BCard },
    template: `<div style="display:flex;gap:var(--space-8);flex-wrap:wrap">
      <BCard :rotate="0.5" style="max-width:16rem;padding:var(--space-6)"><h3>Sticker A</h3><p>Rotated +0.5°.</p></BCard>
      <BCard :rotate="-0.5" style="max-width:16rem;padding:var(--space-6)"><h3>Sticker B</h3><p>Rotated −0.5°.</p></BCard>
    </div>`,
  }),
};
