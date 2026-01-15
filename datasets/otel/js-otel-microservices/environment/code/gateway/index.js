import express from 'express';

const app = express();
app.use(express.json());

const stockApiUrl = 'http://localhost:8081';
const orderApiUrl = 'http://localhost:8082';

async function checkStock(sku, quantity) {
  const response = await fetch(`${stockApiUrl}/check`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ sku, quantity }),
  });
  return response.json();
}

async function createOrder(sku, quantity, userId) {
  const response = await fetch(`${orderApiUrl}/create`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ sku, quantity, user_id: userId }),
  });
  return response.json();
}

app.post('/order', async (req, res) => {
  const { sku, quantity, user_id } = req.body;

  let stockResp;
  try {
    stockResp = await checkStock(sku, quantity);
  } catch {
    return res.json({ success: false, error: 'stock service unavailable' });
  }

  if (!stockResp.available) {
    return res.json({ success: false, error: 'product not available' });
  }

  let orderResp;
  try {
    orderResp = await createOrder(sku, quantity, user_id);
  } catch {
    return res.json({ success: false, error: 'order service unavailable' });
  }

  res.json(orderResp);
});

app.listen(8080, '127.0.0.1', () => {
  console.log('Gateway service running on port 8080');
});
