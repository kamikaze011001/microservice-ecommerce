import type { Meta, StoryObj } from '@storybook/vue3-vite';
import ProductCard from './ProductCard.vue';
import type { ProductDto } from '@/api/queries/products';

const baseProduct: ProductDto = {
  id: 'prod-042',
  name: 'FIELD NOTES — RULED PRESS JACKET',
  price: 28,
  attributes: null,
  quantity: 12,
  category: 'STATIONERY',
  image_url: 'https://placehold.co/600x600',
};

const meta: Meta<typeof ProductCard> = {
  title: 'Patterns/ProductCard',
  component: ProductCard,
  tags: ['autodocs'],
  args: { product: baseProduct },
};
export default meta;

type Story = StoryObj<typeof meta>;

export const InStock: Story = {};

export const SoldOut: Story = {
  args: { product: { ...baseProduct, quantity: 0 } },
};

export const NoImage: Story = {
  args: { product: { ...baseProduct, image_url: null, name: 'LETTERPRESS TOTE BAG' } },
};
