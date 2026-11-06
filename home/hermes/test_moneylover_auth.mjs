// Offline regression tests. Never use the account or its real token cache.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const home = await mkdtemp(path.join(os.tmpdir(), 'moneylover-auth-'));
process.env.HOME = home;
process.env.EMAIL = 'test@example.invalid';
process.env.PASSWORD = 'test-password';
process.env.MONEYLOVER_MCP_DISABLE_ENV_FILE = '1';
delete process.env.MONEYLOVER_TOKEN;
delete process.env.MONEY_LOVER_TOKEN;
const { MoneyloverClient, MoneyloverApiError } = await import('../src/moneyloverClient.js');
const { readToken, writeToken } = await import('../src/tokenCache.js');
const { __test } = await import('../src/server.js');
let logins = 0;
MoneyloverClient.getToken = async () => { logins++; return 'fresh-token'; };

try {
  for (const [label, code, message] of [
    ['observed API response', 706, 'Not authorized error'],
    ['code alone', 706, 'Access rejected'],
    ['message fallback', 999, 'Not authorized error']
  ]) {
    await test(`refresh and retry: ${label}`, async () => {
      __test.clearEnvTokenCache();
      await writeToken(process.env.EMAIL, 'expired-token');
      logins = 0;
      const attempts = [];
      const result = await __test.runWithResolvedToken(undefined, async token => {
        attempts.push(token);
        if (token === 'expired-token') throw new MoneyloverApiError(message, { code });
        return 'wallet-read-ok';
      });
      assert.equal(result, 'wallet-read-ok');
      assert.deepEqual(attempts, ['expired-token', 'fresh-token']);
      assert.equal(logins, 1);
      assert.equal(await readToken(process.env.EMAIL), 'fresh-token');
    });
  }
  await test('retry is bounded when refreshed token is rejected', async () => {
    __test.clearEnvTokenCache();
    await writeToken(process.env.EMAIL, 'expired-token');
    logins = 0;
    let attempts = 0;
    await assert.rejects(__test.runWithResolvedToken(undefined, async () => {
      attempts++;
      throw new MoneyloverApiError('Not authorized error', { code: 706 });
    }));
    assert.equal(attempts, 2);
    assert.equal(logins, 1);
  });
  await test('non-auth failures and explicit caller tokens do not trigger login', async () => {
    __test.clearEnvTokenCache();
    await writeToken(process.env.EMAIL, 'cached-token');
    logins = 0;
    for (const [token, error] of [
      [undefined, new MoneyloverApiError('Invalid wallet', { code: 999 })],
      ['caller-token', new MoneyloverApiError('Not authorized error', { code: 706 })]
    ]) {
      let attempts = 0;
      await assert.rejects(__test.runWithResolvedToken(token, async () => { attempts++; throw error; }));
      assert.equal(attempts, 1);
    }
    assert.equal(logins, 0);
  });
} finally {
  await rm(home, { recursive: true, force: true });
}
