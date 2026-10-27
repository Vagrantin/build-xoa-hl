import assert from 'node:assert/strict'
import { applyCredentials, credentialSession, retryProvisioning } from '../scripts/xoa-apply-credentials.mjs'

function api({ email = 'admin@admin.net', password = 'admin', fail } = {}) {
  let time = 0
  const failures = new Map()
  const attempts = []
  const timing = { now: () => time, sleep: async ms => { time += ms } }
  const user = { id: 'original-admin', email, permission: 'admin' }
  let authenticated = false
  return {
    user, timing, attempts,
    call: async (method, params) => {
      if (fail === method) throw Error('injected failure')
      if (method === 'session.signIn') {
        assert.equal(typeof params.password, 'string')
        attempts.push({ email: params.email, time })
        if (failures.has(params.email) && time - failures.get(params.email) < 2000) {
          throw Error('too fast authentication tries')
        }
        if (params.email !== user.email || params.password !== password) {
          failures.set(params.email, time)
          throw Error('invalid credentials')
        }
        failures.delete(params.email)
        authenticated = true
        return { ...user }
      }
      if (method === 'session.signOut') { authenticated = false; return }
      assert.ok(authenticated)
      if (method === 'user.changePassword') {
        assert.equal(params.oldPassword, password)
        password = params.newPassword
      } else if (method === 'user.set') {
        assert.equal(params.id, user.id)
        user.email = params.email
      } else throw Error(`Unexpected method ${method}`)
    },
  }
}
for (const password of ['true', 'false', 'complex$`"()pass']) {
  for (const initial of [{}, { password }, { email: 'lab@example.test', password }]) {
    const a = api(initial)
    await applyCredentials(a.call, 'lab@example.test', password, a.timing)
    if (initial.email === undefined) {
      assert.ok(a.attempts.at(-1).time >= 2200, 'verification must wait after new-email failure')
    }
    assert.equal((await a.call('session.signIn', { email: 'lab@example.test', password })).id, 'original-admin')
    await assert.rejects(a.call('session.signIn', { email: 'admin@admin.net', password: 'admin' }))
  }
}
// Interrupted between password and email update; retry the same actual state.
const partial = api({ fail: 'user.set' })
await assert.rejects(applyCredentials(partial.call, 'lab@example.test', 'false', partial.timing))
// An unrelated password must not be overwritten by fallback credentials.
const unrelated = api({ password: 'operator-changed' })
await assert.rejects(applyCredentials(unrelated.call, 'lab@example.test', 'false', unrelated.timing))
const mutationFailure = api({ fail: 'user.changePassword' })
await assert.rejects(applyCredentials(mutationFailure.call, 'lab@example.test', 'false', mutationFailure.timing))
// Retaining the upstream login with a changed password is allowed.
const retained = api()
await applyCredentials(retained.call, 'admin@admin.net', 'false', retained.timing)
await assert.rejects(retained.call('session.signIn', { email: 'admin@admin.net', password: 'admin' }))
console.log('Credential API: 9 bootstrap/retry states, string passwords, failures and retained login passed')

// Real transport lifecycle with an in-process fake socket: reconnect before
// startup and after lost mutation replies, while retaining the server state.
for (const disconnectAt of ['open', 'api-startup', 'user.changePassword', 'user.set', 'session.signOut']) {
  const a = api()
  let connections = 0, disconnected = false
  const waits = []
  class Socket {
    constructor() {
      connections++
      queueMicrotask(() => {
        if (disconnectAt === 'open' && !disconnected) {
          disconnected = true
          this.onerror()
        } else this.onopen()
      })
    }
    send(raw) {
      const message = JSON.parse(raw)
      if (disconnectAt === 'api-startup' && connections === 1) {
        queueMicrotask(() => this.onmessage({ data: JSON.stringify({ id: message.id, error: {} }) }))
        return
      }
      a.call(message.method, message.params).then(result => {
        if (message.method === disconnectAt && !disconnected) {
          disconnected = true
          this.onclose()
        } else this.onmessage({ data: JSON.stringify({ id: message.id, result }) })
      }, () => this.onmessage({ data: JSON.stringify({ id: message.id, error: {} }) }))
    }
    close() { this.onclose() }
  }
  await retryProvisioning(() => credentialSession('lab@example.test', 'false', Socket, a.timing), async ms => {
    waits.push(ms)
    await a.timing.sleep(ms)
  })
  assert.equal(connections, 2)
  assert.deepEqual(waits, [3000])
  assert.equal(a.user.email, 'lab@example.test')
  assert.equal((await a.call('session.signIn', { email: 'lab@example.test', password: 'false' })).id, 'original-admin')
}
const unavailable = []
await assert.rejects(retryProvisioning(async () => { unavailable.push('connect'); throw Error('offline') },
  async ms => unavailable.push(ms)), /Credential API failed/)
assert.deepEqual(unavailable, ['connect', 3000, 'connect', 6000, 'connect'])
console.log('Transient startup, disconnects after mutations, and bounded failure retries passed')
