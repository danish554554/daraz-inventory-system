fl# Daraz Inventory System

This package contains the Node.js backend and Flutter mobile app.

## What was fixed

- Store validation now makes a real request to Daraz instead of only checking whether a saved token exists.
- Disabled live API mode now reports a clear error. It no longer pretends that token validation or refresh succeeded.
- Manual, scheduled, and selected-store sync all require `DARAZ_ENABLE_LIVE_API=true`.
- Dashboard and Sync Center refresh their displayed data automatically every 30 seconds and bypass the mobile app cache.
- A `render.yaml` and safe `backend/.env.example` are included.

## Run the backend locally

1. Open the `backend` folder in VS Code.
2. Copy `.env.example` to `.env` and fill in every required value. Never commit `.env`.
3. Run `npm ci`.
4. Run `npm start`.
5. Open `http://localhost:5000/health`. It must return JSON with `success: true`.

## Run the Flutter app

1. Open `mobile_flutter_app` in VS Code.
2. Run `flutter pub get`.
3. Start an emulator or connect a phone.
4. Run `flutter run --dart-define=API_BASE_URL=https://YOUR-RENDER-SERVICE.onrender.com/api`.

The app also has a Settings option for changing its API URL. Use HTTPS for a deployed backend.

## Deploy the backend on Render

1. Push this folder to GitHub.
2. In Render, create a Blueprint from the repository, or create a Node Web Service with root directory `backend`, build command `npm ci`, and start command `npm start`.
3. Add the secrets from `backend/.env.example` in Render's Environment settings. Do not add the `.env` file to GitHub.
4. Set `DARAZ_OAUTH_REDIRECT_URI` to exactly `https://YOUR-RENDER-SERVICE.onrender.com/api/stores/oauth/callback` and register that same URL in Daraz.
5. Use an always-running Render instance or a separate worker/cron job. A sleeping web service cannot run the in-process scheduler reliably.

## Verify live data

1. Visit `/health` and confirm the backend is up.
2. In the app, connect each store through the Daraz OAuth flow.
3. Use **Validate Connection**. It now calls Daraz and reports a real error if the token is invalid.
4. Use **Sync Orders**, then inspect the latest sync status/message in the app.

Daraz data is obtained by polling; it is not a webhook or socket-based feed. The default store sync cadence is five minutes, and the app display refreshes every 30 seconds.
