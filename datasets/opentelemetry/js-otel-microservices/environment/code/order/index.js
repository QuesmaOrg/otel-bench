import express from 'express';

const app = express();
app.use(express.json());

const orders = new Map();
let orderCounter = 0;
const stockApiUrl = 'http://localhost:8081';

async function decreaseStock(sku, quantity) {
  const response = await fetch(`${stockApiUrl}/decrease`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ sku, quantity }),
  });
  return response.json();
}

app.post('/create', async (req, res) => {
  const { sku, quantity, user_id } = req.body;

  let stockResp;
  try {
    stockResp = await decreaseStock(sku, quantity);
  } catch {
    return res.json({ success: false, error: 'stock service unavailable' });
  }

  if (!stockResp.success) {
    return res.json({ success: false, error: 'insufficient stock' });
  }

  orderCounter++;
  const parcelNumber = `PARCEL-${orderCounter}`;
  orders.set(parcelNumber, { sku, quantity, user_id });

  res.json({ success: true, parcel_number: parcelNumber });
});

app.listen(8082, '127.0.0.1', () => {
  console.log('Order service running on port 8082');
});
