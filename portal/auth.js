// Authentication: signup / login / logout via session cookies, plus the
// requireAuth / requireAdmin middleware used to scope the API.

const express = require('express');
const { db, newToken, hashPassword, verifyPassword } = require('./db');

const SESSION_DAYS = 30;
const COOKIE = 'ut_session';
// Secure cookies (HTTPS-only) by default; set UT_INSECURE_COOKIE=1 for local
// http testing. nginx terminates TLS and forwards X-Forwarded-Proto=https.
const SECURE = process.env.UT_INSECURE_COOKIE !== '1';

// The exact attribute set used for BOTH setting and clearing the cookie — they
// must match or the browser won't remove it on logout.
function cookieOpts(basePath) {
  return { httpOnly: true, sameSite: 'lax', secure: SECURE, path: basePath || '/' };
}

function setSessionCookie(res, token, basePath) {
  res.cookie(COOKIE, token, {
    ...cookieOpts(basePath),
    maxAge: SESSION_DAYS * 86400 * 1000,
  });
}

function userFromReq(req) {
  const token = req.cookies?.[COOKIE];
  if (!token) return null;
  const s = db.prepare('SELECT * FROM sessions WHERE token = ?').get(token);
  if (!s || s.expires_at < Date.now()) return null;
  return db.prepare('SELECT id, email, role, created_at FROM users WHERE id = ?').get(s.user_id) || null;
}

// Gate: must be logged in. Attaches req.user.
function requireAuth(req, res, next) {
  const u = userFromReq(req);
  if (!u) return res.status(401).json({ error: 'unauthorized' });
  req.user = u;
  next();
}

// Gate: must be admin.
function requireAdmin(req, res, next) {
  if (req.user?.role !== 'admin') return res.status(403).json({ error: 'forbidden' });
  next();
}

function buildAuthRouter(basePath) {
  const router = express.Router();

  router.post('/signup', (req, res) => {
    const email = String(req.body?.email || '').trim().toLowerCase();
    const password = String(req.body?.password || '');
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return res.status(400).json({ error: 'invalid_email' });
    if (password.length < 6) return res.status(400).json({ error: 'weak_password' });
    if (db.prepare('SELECT id FROM users WHERE email = ?').get(email)) {
      return res.status(409).json({ error: 'email_taken' });
    }
    const info = db.prepare(
      'INSERT INTO users (email, password_hash, role, created_at) VALUES (?, ?, \'user\', ?)'
    ).run(email, hashPassword(password), Date.now());
    issueSession(res, info.lastInsertRowid, basePath);
    res.json({ email, role: 'user' });
  });

  router.post('/login', (req, res) => {
    const email = String(req.body?.email || '').trim().toLowerCase();
    const password = String(req.body?.password || '');
    const u = db.prepare('SELECT * FROM users WHERE email = ?').get(email);
    if (!u || !verifyPassword(password, u.password_hash)) {
      return res.status(401).json({ error: 'invalid_credentials' });
    }
    issueSession(res, u.id, basePath);
    res.json({ email: u.email, role: u.role });
  });

  router.post('/logout', (req, res) => {
    const token = req.cookies?.[COOKIE];
    if (token) db.prepare('DELETE FROM sessions WHERE token = ?').run(token);
    // Clear with the SAME attributes used when setting, or the browser keeps it.
    res.clearCookie(COOKIE, cookieOpts(basePath));
    res.json({ ok: true });
  });

  // No-JS fallback: a plain HTML <form> posts here, we set the session and
  // redirect back to the SPA. Works even if inline scripts are blocked.
  // 303 See Other: forces the follow-up to be a GET (a plain 302 can be
  // replayed as POST → 404 against the static SPA). 303 is the correct status
  // for "POST handled, go look at this other resource with GET".
  router.post('/login-form', (req, res) => {
    const email = String(req.body?.email || '').trim().toLowerCase();
    const password = String(req.body?.password || '');
    const u = db.prepare('SELECT * FROM users WHERE email = ?').get(email);
    if (!u || !verifyPassword(password, u.password_hash)) {
      return res.redirect(303, basePath + '/?err=1');
    }
    issueSession(res, u.id, basePath);
    res.redirect(303, basePath + '/');
  });

  router.post('/signup-form', (req, res) => {
    const email = String(req.body?.email || '').trim().toLowerCase();
    const password = String(req.body?.password || '');
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) || password.length < 6) {
      return res.redirect(303, basePath + '/?signup=1&err=1');
    }
    if (db.prepare('SELECT id FROM users WHERE email = ?').get(email)) {
      return res.redirect(303, basePath + '/?signup=1&err=taken');
    }
    const info = db.prepare(
      'INSERT INTO users (email, password_hash, role, created_at) VALUES (?, ?, \'user\', ?)'
    ).run(email, hashPassword(password), Date.now());
    issueSession(res, info.lastInsertRowid, basePath);
    res.redirect(303, basePath + '/');
  });

  // Who am I — used by the SPA to decide which view to show.
  router.get('/me', (req, res) => {
    const u = userFromReq(req);
    if (!u) return res.status(401).json({ error: 'unauthorized' });
    res.json(u);
  });

  return router;

  function issueSession(res, userId, base) {
    const token = newToken();
    const now = Date.now();
    db.prepare('INSERT INTO sessions (token, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)')
      .run(token, userId, now, now + SESSION_DAYS * 86400 * 1000);
    setSessionCookie(res, token, base);
  }
}

module.exports = { buildAuthRouter, requireAuth, requireAdmin, userFromReq };
