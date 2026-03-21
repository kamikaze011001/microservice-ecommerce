import { sleep, check } from 'k6';
import http from 'k6/http';
import { SharedArray } from 'k6/data';
import { config, generateOrderItems } from '../config.js';
import { login, loginSimple } from '../helpers/auth.js';
import { getAuthHeaders } from '../helpers/token-manager.js';

// Load pre-created test users
const users = new SharedArray('users', function() {
  return config.testUsers;
});

// ============================================
// SETUP: Runs once before all VUs start
// ============================================
export function setup() {
  console.log('=== SETUP PHASE ===');

  // Step 1: Verify gateway is accessible
  const healthRes = http.get(`${config.baseUrl}/actuator/health`);
  if (healthRes.status !== 200) {
    throw new Error(`Gateway not accessible: ${healthRes.status}`);
  }
  console.log('Gateway health check: OK');

  // Step 2: Login as admin
  console.log(`Logging in as admin: ${config.adminUser.username}`);
  const adminTokens = loginSimple(config.adminUser.username, config.adminUser.password);

  if (!adminTokens) {
    throw new Error('Admin login failed! Check admin user exists in database.');
  }
  console.log('Admin login: OK');

  // Step 3: Add inventory to ALL test products
  console.log(`Adding inventory to ${config.testProducts.length} products...`);

  for (const product of config.testProducts) {
    const inventoryUrl = `${config.baseUrl}${config.endpoints.updateInventory}/${product.id}`;
    const inventoryBody = JSON.stringify({
      quantity: product.inventoryToAdd,
      is_add: true
    });

    const inventoryRes = http.patch(inventoryUrl, inventoryBody, {
      headers: {
        'Authorization': `Bearer ${adminTokens.access_token}`,
        'Content-Type': 'application/json'
      },
      tags: { name: 'setup_inventory' }
    });

    const inventoryOk = check(inventoryRes, {
      [`inventory added for ${product.id}`]: (r) => r.status === 200
    });

    if (!inventoryOk) {
      console.error(`Failed to add inventory for ${product.id}: ${inventoryRes.status} - ${inventoryRes.body}`);
      throw new Error(`Inventory setup failed for product: ${product.id}`);
    }

    console.log(`  - Added ${product.inventoryToAdd} units to product ${product.id}`);
  }

  console.log('=== SETUP COMPLETE ===\n');
  return { setupTime: new Date().toISOString() };
}

// ============================================
// MAIN TEST: Runs for each VU iteration
// ============================================
export default function(data) {
  const vu = __VU;
  const user = users[vu % users.length];

  // Step 1: Login (only on first iteration)
  if (__ITER === 0) {
    const loggedIn = login(vu, user.username, user.password);
    if (!loggedIn) {
      console.error(`VU ${vu}: Login failed, skipping iteration`);
      return;
    }
  }

  // Get auth headers (auto-refreshes token if needed)
  const headers = getAuthHeaders(vu);

  sleep(0.5);

  // Step 2: Create Order with MULTIPLE PRODUCTS
  const orderItems = generateOrderItems();  // Generates 2-5 random products

  const orderUrl = `${config.baseUrl}${config.endpoints.createOrder}`;
  const orderBody = JSON.stringify({
    address: '123 Performance Test Street, District 1, HCMC',
    phone_number: '0912345678',
    items: orderItems  // Multiple products per order
  });

  const orderRes = http.post(orderUrl, orderBody, {
    headers,
    tags: { name: 'create_order' }
  });

  const orderSuccess = check(orderRes, {
    'order created (201)': (r) => r.status === 201,
    'has order_id': (r) => r.json('data.order_id') !== undefined
  });

  if (!orderSuccess) {
    console.error(`VU ${vu}: Create order failed: ${orderRes.status} - ${orderRes.body}`);
    console.error(`Order items: ${JSON.stringify(orderItems)}`);
    return;
  }

  const orderId = orderRes.json('data.order_id');
  sleep(0.5);

  // Step 3: Purchase - Create PayPal order
  const purchaseUrl = `${config.baseUrl}${config.endpoints.purchase}?orderId=${orderId}`;

  const purchaseRes = http.post(purchaseUrl, null, {
    headers,
    tags: { name: 'purchase' }
  });

  const purchaseSuccess = check(purchaseRes, {
    'purchase initiated (200)': (r) => r.status === 200,
    'has paypal links': (r) => r.json('data.links') !== undefined
  });

  if (!purchaseSuccess) {
    console.error(`VU ${vu}: Purchase failed: ${purchaseRes.status} - ${purchaseRes.body}`);
    return;
  }

  // Step 4: Find and call the "approve" link
  const links = purchaseRes.json('data.links');
  const approveLink = links.find(link => link.rel === 'approve');

  if (!approveLink) {
    console.error(`VU ${vu}: No approve link found in response`);
    return;
  }

  sleep(0.5);

  // Step 5: Call approve link (PayPal mock)
  // This triggers the mock to call back to SUT at /paypal:success
  const approveRes = http.get(approveLink.href, {
    tags: { name: 'paypal_approve' }
  });

  check(approveRes, {
    'paypal approve success': (r) => r.status === 200 || r.status === 302
  });

  // Think time between iterations
  sleep(2);
}

// ============================================
// TEARDOWN: Runs once after all VUs complete
// ============================================
export function teardown(data) {
  console.log('\n=== TEARDOWN ===');
  console.log(`Test started at: ${data.setupTime}`);
  console.log(`Test ended at: ${new Date().toISOString()}`);
  console.log('=== TEST COMPLETE ===');
}
