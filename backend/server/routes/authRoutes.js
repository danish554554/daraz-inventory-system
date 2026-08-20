const express = require('express');
const protectAdmin = require('../middleware/authMiddleware');
const {
  normalize,
  getAdminUsername,
  verifyPassword,
  issueAdminToken,
  getSecurityConfigSummary,
  hashPassword
} = require('../utils/adminAuth');

const router = express.Router();

const loginAttempts = new Map();
const WINDOW_MS = 15 * 60 * 1000;
const MAX_ATTEMPTS = 7;

function getClientKey(req, username) {
  const forwarded = req.headers['x-forwarded-for'];
  const ip = Array.isArray(forwarded)
    ? forwarded[0]
    : String(forwarded || req.ip || req.socket?.remoteAddress || 'unknown').split(',')[0].trim();

  return `${ip}:${normalize(username).toLowerCase()}`;
}

function getAttemptState(key) {
  const now = Date.now();
  const existing = loginAttempts.get(key);

  if (!existing || now > existing.resetAt) {
    const nextState = { count: 0, resetAt: now + WINDOW_MS };
    loginAttempts.set(key, nextState);
    return nextState;
  }

  return existing;
}

router.post('/login', async (req, res) => {
  try {
    const username = normalize(req.body?.username);
    const password = String(req.body?.password || '');

    if (!username || !password) {
      return res.status(400).json({
        success: false,
        message: 'Username and password are required'
      });
    }

    const attemptKey = getClientKey(req, username);
    const attemptState = getAttemptState(attemptKey);

    if (attemptState.count >= MAX_ATTEMPTS) {
      const retryAfterSeconds = Math.max(1, Math.ceil((attemptState.resetAt - Date.now()) / 1000));
      res.set('Retry-After', String(retryAfterSeconds));

      return res.status(429).json({
        success: false,
        message: 'Too many login attempts. Please try again later.'
      });
    }

    const expectedUsername = getAdminUsername();
    const validCredentials = username === expectedUsername && verifyPassword(password);

    if (!validCredentials) {
      attemptState.count += 1;

      return res.status(401).json({
        success: false,
        message: 'Invalid username or password'
      });
    }

    loginAttempts.delete(attemptKey);

    const session = issueAdminToken();

    return res.status(200).json({
      success: true,
      message: 'Login successful',
      token: session.token,
      expiresAt: session.expiresAt,
      expiresInSeconds: session.expiresInSeconds,
      user: session.user
    });
  } catch (error) {
    console.error('[Auth Login Error]', error);

    return res.status(500).json({
      success: false,
      message: 'Failed to login'
    });
  }
});

router.get('/me', protectAdmin, (req, res) => {
  return res.status(200).json({
    success: true,
    user: req.admin,
    session: {
      expiresAt: req.auth?.exp ? new Date(req.auth.exp * 1000).toISOString() : null
    }
  });
});

router.get('/security-status', protectAdmin, (req, res) => {
  return res.status(200).json({
    success: true,
    config: getSecurityConfigSummary()
  });
});

router.post('/hash-password', protectAdmin, (req, res) => {
  const password = String(req.body?.password || '');

  if (!password) {
    return res.status(400).json({
      success: false,
      message: 'Password is required'
    });
  }

  return res.status(200).json({
    success: true,
    hash: hashPassword(password),
    message: 'Copy this hash into ADMIN_PASSWORD_HASH and remove ADMIN_PASSWORD from your .env'
  });
});

module.exports = router;
