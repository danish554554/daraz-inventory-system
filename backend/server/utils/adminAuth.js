const crypto = require('crypto');

const TOKEN_ALGO = 'sha256';
const TOKEN_VERSION = 'v1';
const DEFAULT_SESSION_HOURS = 12;

function normalize(value) {
  return String(value || '').trim();
}

function base64UrlEncode(value) {
  return Buffer.from(value).toString('base64url');
}

function base64UrlDecode(value) {
  return Buffer.from(String(value || ''), 'base64url').toString('utf8');
}

function safeJsonParse(value) {
  try {
    return JSON.parse(value);
  } catch (error) {
    return null;
  }
}

function getAdminUsername() {
  return normalize(process.env.ADMIN_USERNAME || 'admin');
}

function getAdminPassword() {
  return String(process.env.ADMIN_PASSWORD || '');
}

function getAdminPasswordHash() {
  return normalize(process.env.ADMIN_PASSWORD_HASH || '');
}

function getAuthSecret() {
  const directSecret = normalize(process.env.ADMIN_AUTH_SECRET || process.env.JWT_SECRET || '');

  if (directSecret) {
    return directSecret;
  }

  const fallbackSeed = `${getAdminUsername()}:${getAdminPassword() || 'daraz-admin-password'}:fallback-secret`;

  return crypto.createHash('sha256').update(fallbackSeed).digest('hex');
}

function getSessionHours() {
  const raw = Number(process.env.ADMIN_SESSION_HOURS || DEFAULT_SESSION_HOURS);

  if (!Number.isFinite(raw) || raw <= 0) {
    return DEFAULT_SESSION_HOURS;
  }

  return Math.min(raw, 24 * 14);
}

function timingSafeEqualString(a, b) {
  const left = Buffer.from(String(a || ''));
  const right = Buffer.from(String(b || ''));

  if (left.length !== right.length) {
    return false;
  }

  return crypto.timingSafeEqual(left, right);
}

function verifyPassword(password) {
  const providedPassword = String(password || '');
  const configuredHash = getAdminPasswordHash();

  if (configuredHash) {
    const [method, salt, storedHash] = configuredHash.split('$');

    if (method !== 'scrypt' || !salt || !storedHash) {
      return false;
    }

    const derived = crypto.scryptSync(providedPassword, salt, 64).toString('hex');
    return timingSafeEqualString(derived, storedHash);
  }

  const configuredPassword = getAdminPassword();

  if (!configuredPassword) {
    return false;
  }

  return timingSafeEqualString(providedPassword, configuredPassword);
}

function signPayload(payload) {
  return crypto
    .createHmac(TOKEN_ALGO, getAuthSecret())
    .update(payload)
    .digest('base64url');
}

function issueAdminToken() {
  const nowSeconds = Math.floor(Date.now() / 1000);
  const expiresAtSeconds = nowSeconds + getSessionHours() * 60 * 60;

  const header = {
    alg: 'HS256',
    typ: 'JWT'
  };

  const body = {
    sub: getAdminUsername(),
    role: 'admin',
    iat: nowSeconds,
    exp: expiresAtSeconds,
    ver: TOKEN_VERSION
  };

  const encodedHeader = base64UrlEncode(JSON.stringify(header));
  const encodedBody = base64UrlEncode(JSON.stringify(body));
  const unsignedToken = `${encodedHeader}.${encodedBody}`;
  const signature = signPayload(unsignedToken);

  return {
    token: `${unsignedToken}.${signature}`,
    expiresAt: new Date(expiresAtSeconds * 1000).toISOString(),
    expiresInSeconds: expiresAtSeconds - nowSeconds,
    user: {
      username: getAdminUsername(),
      role: 'admin'
    }
  };
}

function verifyAdminToken(token) {
  const rawToken = normalize(token);

  if (!rawToken) {
    return { valid: false, reason: 'missing' };
  }

  const parts = rawToken.split('.');

  if (parts.length !== 3) {
    return { valid: false, reason: 'malformed' };
  }

  const [encodedHeader, encodedBody, signature] = parts;
  const unsignedToken = `${encodedHeader}.${encodedBody}`;
  const expectedSignature = signPayload(unsignedToken);

  if (!timingSafeEqualString(signature, expectedSignature)) {
    return { valid: false, reason: 'invalid_signature' };
  }

  const header = safeJsonParse(base64UrlDecode(encodedHeader));
  const payload = safeJsonParse(base64UrlDecode(encodedBody));

  if (!header || !payload) {
    return { valid: false, reason: 'invalid_payload' };
  }

  if (payload.ver !== TOKEN_VERSION || payload.role !== 'admin') {
    return { valid: false, reason: 'invalid_version' };
  }

  const nowSeconds = Math.floor(Date.now() / 1000);

  if (!payload.exp || Number(payload.exp) <= nowSeconds) {
    return { valid: false, reason: 'expired', payload };
  }

  return {
    valid: true,
    payload,
    user: {
      username: payload.sub || getAdminUsername(),
      role: 'admin'
    }
  };
}

function hashPassword(plainPassword) {
  const password = String(plainPassword || '');

  if (!password) {
    throw new Error('Password is required');
  }

  const salt = crypto.randomBytes(16).toString('hex');
  const hashed = crypto.scryptSync(password, salt, 64).toString('hex');

  return `scrypt$${salt}$${hashed}`;
}

function getSecurityConfigSummary() {
  return {
    usernameConfigured: Boolean(getAdminUsername()),
    passwordHashConfigured: Boolean(getAdminPasswordHash()),
    plainPasswordConfigured: Boolean(getAdminPassword()),
    secretConfigured: Boolean(normalize(process.env.ADMIN_AUTH_SECRET || process.env.JWT_SECRET || '')),
    sessionHours: getSessionHours()
  };
}

module.exports = {
  normalize,
  getAdminUsername,
  verifyPassword,
  issueAdminToken,
  verifyAdminToken,
  hashPassword,
  getSecurityConfigSummary
};
