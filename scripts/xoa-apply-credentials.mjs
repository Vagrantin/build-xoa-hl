// Local bootstrap only. XO is pinned to 5.113.2. Passwords remain strings.
export async function applyCredentials(call, email, password) {
  let user, currentPassword
  // Covers complete, password-only, and untouched bootstrap states.
  for (const [login, candidate] of [[email, password], ['admin@admin.net', password], ['admin@admin.net', 'admin']]) {
    try {
      user = await call('session.signIn', { email: login, password: candidate })
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
  const verified = await call('session.signIn', { email, password })
  if (verified.id !== user.id) throw Error('Unexpected provisioning user')
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  const ws = new WebSocket('wss://127.0.0.1/api/')
  const pending = new Map()
  let id = 0
  const timeout = setTimeout(() => { console.error('Credential API timed out'); process.exit(1) }, 120000)
  const fail = () => { console.error('Credential API failed'); process.exit(1) }
  const call = (method, params) => new Promise((resolve, reject) => {
    const requestId = ++id
    pending.set(requestId, { resolve, reject })
    ws.send(JSON.stringify({ jsonrpc: '2.0', id: requestId, method, params }))
  })
  ws.onmessage = event => {
    try {
      const message = JSON.parse(event.data)
      const waiter = pending.get(message.id)
      if (waiter === undefined) return
      pending.delete(message.id)
      if (message.error) waiter.reject(Error('Credential request rejected'))
      else waiter.resolve(message.result)
    } catch { fail() }
  }
  ws.onerror = fail
  ws.onclose = fail
  ws.onopen = async () => {
    try {
      await applyCredentials(call, process.env.XOA_EMAIL, process.env.XOA_PASSWORD)
      clearTimeout(timeout)
      process.exit(0)
    } catch { fail() }
  }
}
