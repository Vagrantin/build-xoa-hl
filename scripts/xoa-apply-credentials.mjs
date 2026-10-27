import { setTimeout as sleep } from 'node:timers/promises'

// Local bootstrap only. XO is pinned to 5.113.2. Passwords remain strings.
export async function applyCredentials(call, email, password, timing = { now: Date.now, sleep }) {
  // XO 5.113.2 throttles each username for 2000 ms after a failed sign-in.
  // Also guard the final verification: the new email may have failed earlier.
  const failures = new Map()
  const signIn = async (login, candidate) => {
    if (failures.has(login)) {
      const remaining = failures.get(login) + 2200 - timing.now()
      if (remaining > 0) await timing.sleep(remaining)
    }
    try {
      return await call('session.signIn', { email: login, password: candidate })
    } catch (error) {
      failures.set(login, timing.now())
      throw error
    }
  }
  let user, currentPassword
  // Covers complete, password-only, and untouched bootstrap states.
  for (const [login, candidate] of [[email, password], ['admin@admin.net', password], ['admin@admin.net', 'admin']]) {
    try {
      user = await signIn(login, candidate)
      currentPassword = candidate
      break
    } catch { /* Try the next known bootstrap state. */ }
  }
  if (user === undefined) throw Error('Cannot authenticate bootstrap account')
  if (currentPassword !== password) {
    await call('user.changePassword', { oldPassword: currentPassword, newPassword: password })
  }
  if (user.email !== email) await call('user.set', { id: user.id, email })
  // A fresh session verifies both fields before persistence/completion.
  await call('session.signOut', {})
  const verified = await signIn(email, password)
  if (verified.id !== user.id) throw Error('Unexpected provisioning user')
}

// Reconnect after transient startup/transport failures. A lost mutation reply is
// safe to retry because applyCredentials recognizes the intermediate states.
export async function retryProvisioning(run, wait = sleep) {
  for (let attempt = 0; ; attempt++) {
    try { return await run() } catch {
      if (attempt === 2) throw Error('Credential API failed')
      await wait(3000 * (attempt + 1))
    }
  }
}

export function credentialSession(email, password, Socket = WebSocket, timing) {
  return new Promise((resolve, reject) => {
    const ws = new Socket('wss://127.0.0.1/api/')
    const pending = new Map()
    let id = 0, settled = false
    const finish = error => {
      if (settled) return
      settled = true
      for (const waiter of pending.values()) waiter.reject(Error('Credential connection closed'))
      pending.clear()
      ws.close()
      if (error) reject(Error('Credential API failed'))
      else resolve()
    }
    const call = (method, params) => new Promise((resolve, reject) => {
      if (settled) { reject(Error('Credential connection closed')); return }
      const requestId = ++id
      pending.set(requestId, { resolve, reject })
      try { ws.send(JSON.stringify({ jsonrpc: '2.0', id: requestId, method, params })) }
      catch { finish(true) }
    })
    ws.onmessage = event => {
      try {
        const message = JSON.parse(event.data)
        const waiter = pending.get(message.id)
        if (waiter === undefined) return
        pending.delete(message.id)
        if (message.error) waiter.reject(Error('Credential request rejected'))
        else waiter.resolve(message.result)
      } catch { finish(true) }
    }
    ws.onerror = ws.onclose = () => finish(true)
    ws.onopen = () => applyCredentials(call, email, password, timing).then(() => finish(), () => finish(true))
  })
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  const timeout = setTimeout(() => { console.error('Credential API timed out'); process.exit(1) }, 120000)
  try {
    await retryProvisioning(() => credentialSession(process.env.XOA_EMAIL, process.env.XOA_PASSWORD))
    clearTimeout(timeout)
    process.exit(0)
  } catch {
    console.error('Credential API failed')
    process.exit(1)
  }
}
