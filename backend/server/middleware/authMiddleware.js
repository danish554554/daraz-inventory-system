const { normalize, verifyAdminToken } = require('../utils/adminAuth');

function getBearerToken(req) {
  const authHeader = req.headers.authorization || req.headers.Authorization || '';

  if (!authHeader || typeof authHeader !== 'string') {
    return '';
  }

  const [scheme, token] = authHeader.split(' ');

  if (normalize(scheme).toLowerCase() !== 'bearer') {
    return '';
  }

  return normalize(token);
}

function protectAdmin(req, res, next) {
  try {
    const token = getBearerToken(req);

    if (!token) {
      return res.status(401).json({
        success: false,
        message: 'Authorization token is required'
      });
    }

    const verification = verifyAdminToken(token);

    if (!verification.valid) {
      const message = verification.reason === 'expired'
        ? 'Session expired. Please login again.'
        : 'Invalid authorization token';

      return res.status(401).json({
        success: false,
        message,
        code: verification.reason || 'unauthorized'
      });
    }

    req.admin = verification.user;
    req.auth = verification.payload;

    return next();
  } catch (error) {
    console.error('[Auth Middleware Error]', error);

    return res.status(500).json({
      success: false,
      message: 'Authentication failed'
    });
  }
}

module.exports = protectAdmin;
