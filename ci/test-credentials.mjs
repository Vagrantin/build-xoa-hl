import assert from 'node:assert/strict'
import { applyCredentials } from '../scripts/xoa-apply-credentials.mjs'

function api({ email = 'admin@admin.net', password = 'admin', fail } = {}) {
  const user = { id: 'original-admin', email, permission: 'admin' }
  let authenticated = false
  return {
    user,
    call: async (method, params) => {
      if (fail === method) throw Error('injected failure')
      if (method === 'session.signIn') {
        assert.equal(typeof params.password, 'string')
        if (params.email !== user.email || params.password !== password) throw Error('invalid credentials')
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
    await applyCredentials(a.call, 'lab@example.test', password)
    assert.equal((await a.call('session.signIn', { email: 'lab@example.test', password })).id, 'original-admin')
    await assert.rejects(a.call('session.signIn', { email: 'admin@admin.net', password: 'admin' }))
  }
}
// Interrupted between password and email update; retry the same actual state.
const partial = api({ fail: 'user.set' })
await assert.rejects(applyCredentials(partial.call, 'lab@example.test', 'false'))
// An unrelated password must not be overwritten by fallback credentials.
await assert.rejects(applyCredentials(api({ password: 'operator-changed' }).call, 'lab@example.test', 'false'))
await assert.rejects(applyCredentials(api({ fail: 'user.changePassword' }).call, 'lab@example.test', 'false'))
// Retaining the upstream login with a changed password is allowed.
const retained = api()
await applyCredentials(retained.call, 'admin@admin.net', 'false')
await assert.rejects(retained.call('session.signIn', { email: 'admin@admin.net', password: 'admin' }))
console.log('Credential API: 9 bootstrap/retry states, string passwords, failures and retained login passed')
