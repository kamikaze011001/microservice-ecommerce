// Flows for scripts/db/db-lag-proof.sh — runs INSIDE the env's namespace
// (node:20-alpine, plain fetch, no deps) against http://gateway:6868.
//
//   node db-lag-proof.js flows            → one JSON line: { checks: [...], orderIds: [...], cart: {...} }
//   node db-lag-proof.js cleanup '<json>' → puts the cart quantity back, cancels the orders
//
// Every check is a WRITE followed at once by the READ that used to go to a
// replica (old images: Slave*Repo). The driver keeps the replicas ~10 s behind
// while `flows` runs, so a read that still hits a replica sees the past.
const BASE = process.env.BASE_URL || "http://gateway:6868";
const USER = process.env.PROOF_USER || "perftest_user_100";
const PASS = process.env.PROOF_PASS || "Test@123456";
const PRODUCT = process.env.PROOF_PRODUCT || "67c000000000000000000001";
const CART_PRODUCT = process.env.PROOF_CART_PRODUCT || "67c000000000000000000002";

let token;
async function call(method, path, body) {
  const res = await fetch(BASE + path, {
    method,
    headers: { "content-type": "application/json", ...(token && { authorization: `Bearer ${token}` }) },
    body: body && JSON.stringify(body),
  });
  let json = null;
  try { json = await res.json(); } catch { /* empty body */ }
  return { status: res.status, data: json && json.data };
}

async function login() {
  const r = await call("POST", "/authorization-server/v1/auth:login", { username: USER, password: PASS });
  if (r.status !== 200) throw new Error(`login ${r.status}`);
  token = r.data.access_token;
}

const cartQty = async () => {
  const r = await call("GET", "/order-service/v1/shopping-carts");
  const row = (r.data?.shopping_carts || []).find((i) => i.product_id === CART_PRODUCT);
  return { id: row?.id, qty: row ? Number(row.quantity) : 0 };
};

const createOrder = async () => {
  const r = await call("POST", "/order-service/v1/orders", {
    address: "db-lag-proof", phone_number: "0912345678",
    items: [{ product_id: PRODUCT, quantity: 1 }],
  });
  if (r.status !== 201) throw new Error(`create order ${r.status}`);
  return r.data.order_id;
};

async function flows() {
  await login();
  const checks = [], orderIds = [];
  const check = (name, pass, got) => checks.push({ name, pass, got });

  // 1. cart: add 1, read the cart back (old: SlaveShoppingCartRepo)
  const before = await cartQty();
  await call("POST", "/order-service/v1/shopping-carts:add-item", { product_id: CART_PRODUCT, quantity: 1, price: 58.0 });
  const after = await cartQty();
  check("cart shows the item just added", after.qty === before.qty + 1, `qty ${before.qty} → ${after.qty}`);

  // 2. order detail right after checkout (old: SlaveOrderRepo.findByIdAndUserId)
  // 3. order history right after checkout (@ReplicaRead — with every replica
  //    shunned it must fall back to the primary). The page is unsorted, so
  //    compare the total, not page 1.
  const historyTotal = async () => {
    const r = await call("GET", "/order-service/v1/orders?page=1&size=1");
    return r.status === 200 ? Number(r.data?.total) : NaN;
  };
  const t0 = await historyTotal();
  const o1 = await createOrder(); orderIds.push(o1);
  const d = await call("GET", `/order-service/v1/orders/${o1}`);
  check("order detail right after create", d.status === 200 && d.data?.id === o1, `HTTP ${d.status}`);
  const t1 = await historyTotal();
  check("order history counts the new order", t1 === t0 + 1, `total ${t0} → ${t1}`);

  // 4. cancel right after create (old: SlaveOrderRepo.findById → 404)
  const o2 = await createOrder(); orderIds.push(o2);
  const c = await call("PATCH", `/order-service/v1/orders/${o2}:cancel`);
  check("cancel right after create", c.status === 200 && c.data?.status === "CANCELED", `HTTP ${c.status} ${c.data?.status ?? ""}`.trim());

  console.log(JSON.stringify({ checks, orderIds, cart: { id: after.id || before.id, qty: before.qty } }));
}

// Runs after the delay is gone: put the cart back, and ask to cancel the
// orders. Today "cancel" only cancels the payment attempt — the saga stays
// AWAITING_PAYMENT and the order leaves PROCESSING when its pending-order
// entry expires (~24 h), same as the Bruno suite's orders.
async function cleanup(state) {
  await login();
  for (const id of state.orderIds) await call("PATCH", `/order-service/v1/orders/${id}:cancel`);
  const now = await cartQty();
  if (now.id) {
    if (state.cart.qty > 0) await call("PATCH", "/order-service/v1/shopping-carts:update-item", { shopping_cart_item_id: now.id, quantity: state.cart.qty });
    else await call("DELETE", `/order-service/v1/shopping-carts:delete-item?itemId=${now.id}`);
  }
  console.log("cleanup done");
}

// `node file.js a b` → argv[2..]; `node -e code -- a b` (how the driver runs it) → argv[1..]
const [mode, arg] = process.argv.slice(process.argv[1]?.endsWith(".js") ? 2 : 1);
(mode === "cleanup" ? cleanup(JSON.parse(arg)) : flows()).catch((e) => {
  console.log(JSON.stringify({ error: String(e.message || e) }));
  process.exit(2);
});
