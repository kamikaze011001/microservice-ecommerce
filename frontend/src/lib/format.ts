export interface AddressParts {
  street: string;
  city: string;
  state: string;
  postcode: string;
  country: string;
}

export function formatAddress(p: AddressParts): string {
  return `${p.street}, ${p.city}, ${p.state} ${p.postcode}, ${p.country}`;
}

export function formatCurrency(amount: number, currency = 'USD'): string {
  return new Intl.NumberFormat('en-US', { style: 'currency', currency }).format(amount);
}
