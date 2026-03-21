export const config = {
  // Gateway is the single entry point
  baseUrl: __ENV.BASE_URL || 'http://localhost:6868',

  // All services accessed via gateway
  endpoints: {
    login: '/authorization-server/v1/auth:login',
    refreshToken: '/authorization-server/v1/auth:refresh-token',
    createOrder: '/order-service/v1/orders',
    purchase: '/payment-service/v1/payments',
    updateInventory: '/inventory-service/v1/inventories'
  },

  // Token config
  token: {
    accessTokenTTL: 15 * 60 * 1000,      // 15 minutes in ms
    refreshBeforeExpiry: 2 * 60 * 1000,  // Refresh 2 min before expiry
  },

  // Admin user for setup (created in seed script)
  adminUser: {
    username: 'perftest_admin',
    password: 'Admin@123456'
  },

  // Pre-created test users (generate 100+ for high concurrency)
  testUsers: [
    { username: 'perftest_user_1', password: 'Test@123456' },
    { username: 'perftest_user_2', password: 'Test@123456' },
    { username: 'perftest_user_3', password: 'Test@123456' },
  ],

  // Multiple test products for realistic orders
  // Override via env: PRODUCT_IDS="id1,id2,id3"
  testProducts: __ENV.PRODUCT_IDS
    ? __ENV.PRODUCT_IDS.split(',').map(id => ({ id: id.trim(), inventoryToAdd: 1000000 }))
    : [
        { id: 'test-product-1', inventoryToAdd: 1000000 },
        { id: 'test-product-2', inventoryToAdd: 1000000 },
        { id: 'test-product-3', inventoryToAdd: 1000000 },
      ],

  // Order configuration
  order: {
    minProducts: 2,        // Minimum products per order
    maxProducts: 5,        // Maximum products per order
    minQuantity: 1,        // Minimum quantity per product
    maxQuantity: 3         // Maximum quantity per product
  }
};

// Generate 100 test users programmatically
for (let i = 4; i <= 100; i++) {
  config.testUsers.push({
    username: `perftest_user_${i}`,
    password: 'Test@123456'
  });
}

// Helper function to generate random order items
export function generateOrderItems() {
  const numProducts = Math.floor(Math.random() *
    (config.order.maxProducts - config.order.minProducts + 1)) + config.order.minProducts;

  // Shuffle and pick random products
  const shuffled = [...config.testProducts].sort(() => Math.random() - 0.5);
  const selectedProducts = shuffled.slice(0, Math.min(numProducts, shuffled.length));

  return selectedProducts.map(product => ({
    product_id: product.id,
    quantity: Math.floor(Math.random() *
      (config.order.maxQuantity - config.order.minQuantity + 1)) + config.order.minQuantity
  }));
}
