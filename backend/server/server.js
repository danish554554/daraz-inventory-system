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

  if (!security.plainPasswordConfigured && !security.passwordHashConfigured) {
    warnings.push('No admin password is configured. Login will fail until ADMIN_PASSWORD or ADMIN_PASSWORD_HASH is set.');
  }

  warnings.forEach((warning) => {
    console.warn(`[Startup Warning] ${warning}`);
  });
}

connectDB();
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

app.use('/api/auth', authRoutes);
app.use('/api/stores/oauth', darazOauthRoutes);
app.use('/api/daraz/oauth', darazOauthRoutes);
app.use('/api/stores', protectAdmin, storeRoutes);
app.use('/api/central-inventory', protectAdmin, centralInventoryRoutes);
app.use('/api/daraz-sync', protectAdmin, darazSyncRoutes);
app.use('/api/products', protectAdmin, productRoutes);

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
