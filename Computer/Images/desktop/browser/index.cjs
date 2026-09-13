'use strict';

const puppeteer = require('puppeteer-core');

// Attach only. The desktop owns browser startup, its profile and its lifetime.
async function connect() {
  try {
    return await puppeteer.connect({
      browserURL: 'http://127.0.0.1:9222',
      defaultViewport: null,
      protocolTimeout: 30_000,
    });
  } catch (cause) {
    throw new Error(
      'Cannot attach to the Noodle desktop browser. Open Browser on the desktop ' +
      'or run chromium in the guest terminal, then retry. Older computers need ' +
      'an image Update to support browser automation.',
      { cause },
    );
  }
}

module.exports = { connect };
