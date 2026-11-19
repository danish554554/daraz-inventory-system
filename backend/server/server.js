// Silence Mongoose 8/9 deprecation warning: the 'new' option for findOneAndUpdate()
const originalEmitWarning = process.emitWarning;
process.emitWarning = function(warning, ...args) {
  if (
    (typeof warning === 'string' && warning.includes("the 'new' option for 'findOneAndUpdate()'")) ||
    (warning && warning.message && warning.message.includes("the 'new' option for 'findOneAndUpdate()'"))
  ) {
    return;
  }
  return originalEmitWarning.call(process, warning, ...args);
};

const path = require('path');
const dotenv = require('dotenv');

dotenv.config({ path: path.join(__dirname, '.env') });
dotenv.config();

const express = require('express');
const cors = require('cors');

const connectDB = require('./config/db');
const protectAdmin = require('./middleware/authMiddleware');
const darazOauthRoutes = require('./routes/darazOauthRoutes');
const authRoutes = require('./routes/authRoutes');
const storeRoutes = require('./routes/storeRoutes');
const centralInventoryRoutes = require('./routes/centralInventoryRoutes');
const darazSyncRoutes = require('./routes/darazSyncRoutes');
const productRoutes = require('./routes/productRoutes');
const financeRoutes = require('./routes/financeRoutes');
const purchaseRoutes = require('./routes/purchaseRoutes');
const stockRoutes = require('./routes/stockRoutes');
const notificationRoutes = require('./routes/notificationRoutes');
const { startOrderSyncScheduler } = require('./services/orderSyncScheduler');
const { getSecurityConfigSummary } = require('./utils/adminAuth');

const app = express();

function normalize(value) {
  return String(value || '').trim();
}

function getAllowedOrigins() {
  const raw = normalize(process.env.CORS_ALLOWED_ORIGINS || '');

  if (!raw) {
    return [];
  }

  return raw
    .split(',')
    .map((item) => normalize(item))
    .filter(Boolean);
}

function securityHeaders(req, res, next) {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
  res.setHeader('X-Permitted-Cross-Domain-Policies', 'none');
  res.setHeader('Cross-Origin-Resource-Policy', 'same-site');
  next();
}

function startupChecks() {
  const warnings = [];
  const security = getSecurityConfigSummary();

  if (!process.env.MONGO_URI) {
    warnings.push('MONGO_URI is missing. Database connection will fail.');
  }

  if (!security.secretConfigured) {
    warnings.push('ADMIN_AUTH_SECRET is missing. A fallback secret is being used. Set a strong custom secret in production.');
  }

  if (!security.passwordHashConfigured) {
    warnings.push('ADMIN_PASSWORD_HASH is not configured. Use a password hash instead of storing ADMIN_PASSWORD in plain text.');
  }

  if (getAllowedOrigins().length === 0) {
    warnings.push('CORS_ALLOWED_ORIGINS is not set. Browser requests from any origin are accepted (API still requires a bearer token).');
  }

  if (!security.plainPasswordConfigured && !security.passwordHashConfigured) {
    warnings.push('No admin password is configured. Login will fail until ADMIN_PASSWORD or ADMIN_PASSWORD_HASH is set.');
  }

  warnings.forEach((warning) => {
    console.warn(`[Startup Warning] ${warning}`);
  });
}

connectDB().then(() => {
  if (typeof financeRoutes.autoHealFinanceEntries === 'function') {
    financeRoutes.autoHealFinanceEntries(true).catch((err) => {
      console.warn('[Startup] Non-blocking autoHeal notice:', err.message);
    });
  }
}).catch((err) => {
  console.error('[Startup] DB connect error:', err.message);
});
startupChecks();

if (process.env.TRUST_PROXY === 'true') {
  app.set('trust proxy', 1);
}

const allowedOrigins = getAllowedOrigins();

app.use(securityHeaders);
app.use(
  cors({
    origin(origin, callback) {
      if (!origin || allowedOrigins.length === 0 || allowedOrigins.includes(origin)) {
        return callback(null, true);
      }

      return callback(new Error('CORS origin not allowed'));
    },
    credentials: false
  })
);

app.use(express.json({ limit: '2mb' }));
app.use(express.urlencoded({ extended: true, limit: '2mb' }));

app.get('/', (req, res) => {
  res.send('Daraz Inventory API is running');
});

app.get('/health', (req, res) => {
  return res.status(200).json({
    success: true,
    service: 'daraz-inventory-api',
    uptimeSeconds: Math.floor(process.uptime()),
    timestamp: new Date().toISOString()
  });
});

app.get('/health/qa-audit', async (req, res) => {
  try {
    if (typeof financeRoutes.autoHealFinanceEntries === 'function') {
      await financeRoutes.autoHealFinanceEntries(true);
    }

    const FinanceEntry = require('./models/FinanceEntry');
    const CentralInventory = require('./models/CentralInventory');
    const Product = require('./models/Product');

    const trimmerOrders = await FinanceEntry.find({
      order_number: { $in: ['251776120072486', '250836068328754', '252103981308557'] }
    }).select('order_number seller_sku product_name cost_price total_cost net_settlement net_profit profit_ready order_status').lean();

    const returnedOrders = await FinanceEntry.find({
      order_status: { $regex: /return/i }
    }).select('order_number seller_sku product_name cost_price total_cost net_settlement net_profit profit_ready order_status').limit(10).lean();

    const trimmerInv = await CentralInventory.find({
      seller_sku: { $regex: /1953371685/i }
    }).select('seller_sku product_name cost_price purchase_price store_id').lean();

    const removerInv = await CentralInventory.find({
      seller_sku: { $regex: /923171376/i }
    }).select('seller_sku product_name cost_price purchase_price store_id').lean();

    return res.status(200).json({
      success: true,
      timestamp: new Date().toISOString(),
      trimmerOrders,
      returnedOrders,
      trimmerInv,
      removerInv
    });
  } catch (error) {
    return res.status(500).json({ success: false, error: error.message });
  }
});

app.use('/api/auth', authRoutes);
app.use('/api/stores/oauth', darazOauthRoutes);
app.use('/api/daraz/oauth', darazOauthRoutes);
app.use('/api/stores', protectAdmin, storeRoutes);
app.use('/api/central-inventory', protectAdmin, centralInventoryRoutes);
app.use('/api/daraz-sync', protectAdmin, darazSyncRoutes);
app.use('/api/products', protectAdmin, productRoutes);
app.use('/api/finance', protectAdmin, financeRoutes);
app.use('/api/purchases', protectAdmin, purchaseRoutes);
app.use('/api/stocks', protectAdmin, stockRoutes);
app.use('/api/notifications', protectAdmin, notificationRoutes);

app.use((req, res) => {
  return res.status(404).json({
    success: false,
    message: 'Route not found'
  });
});

app.use((err, req, res, next) => {
  console.error('[Server Error]', err);

  return res.status(err.status || 500).json({
    success: false,
    message: err.message || 'Internal server error'
  });
});

const PORT = Number(process.env.PORT) || 5000;

app.listen(PORT, '0.0.0.0', () => {
  console.log(`Server running on port ${PORT}`);
  startOrderSyncScheduler();
});
