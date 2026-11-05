'use strict';
/**
 * SplitNest backend entry point.
 * PRACTICE ONLY — NOT FOR SUBMISSION.
 * Usage: PORT=3000 DB_PATH=./splitnest.db node src/server.js
 */
const path = require('path');
const { createApp } = require('./app');

const PORT = parseInt(process.env.PORT || '3000', 10);
const DB_PATH = process.env.DB_PATH || path.join(__dirname, '..', 'splitnest.db');

const { app } = createApp(DB_PATH);
const server = app.listen(PORT, '0.0.0.0', () => {
  console.log(`SplitNest backend (practice) listening on http://0.0.0.0:${PORT}`);
  console.log(`Database file: ${DB_PATH}`);
});

process.on('SIGINT', () => server.close(() => process.exit(0)));
process.on('SIGTERM', () => server.close(() => process.exit(0)));
