const API_BASE = import.meta.env.VITE_API_BASE_URL || ''

// Cache the session lookup for a short window. Feed pages mount N cards
// at once, each of which calls getSession(). Without this, that's N
// requests to /api/sessions/me for the same answer.
let sessionCache = { value: undefined, timestamp: 0 }
const SESSION_CACHE_MS = 1000

export async function listVideos(username, cursor = null, limit = 50) {
  const params = new URLSearchParams({ limit: String(limit) })
  if (cursor) params.set('cursor', cursor)
  const res = await fetch(
    `${API_BASE}/api/users/${encodeURIComponent(username)}/videos?${params}`
  )
  if (res.status === 404) return { totalItems: 0, items: [], next_cursor: null }
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return await res.json()
}

export async function getTimeline(username, cursor = null, limit = 50) {
  const params = new URLSearchParams({ limit: String(limit) })
  if (cursor) params.set('cursor', cursor)
  const res = await fetch(
    `${API_BASE}/api/users/${encodeURIComponent(username)}/timeline?${params}`,
    { credentials: 'include' }
  )
  if (res.status === 401) throw new Error('Not logged in')
  if (res.status === 404) return { totalItems: 0, items: [], next_cursor: null }
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return await res.json()
}

export async function getLocalFeed(cursor = null, limit = 50, tag = null) {
  const params = new URLSearchParams({ limit: String(limit) })
  if (cursor) params.set('cursor', cursor)
  if (tag) params.set('tag', tag)
  const res = await fetch(`${API_BASE}/api/timeline/local?${params}`)
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return await res.json()
}

export async function getFederatedFeed(cursor = null, limit = 50, tag = null) {
  const params = new URLSearchParams({ limit: String(limit) })
  if (cursor) params.set('cursor', cursor)
  if (tag) params.set('tag', tag)
  const res = await fetch(`${API_BASE}/api/timeline/federated?${params}`)
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return await res.json()
}

export async function getSession() {
  const now = Date.now()
  if (sessionCache.value !== undefined && now - sessionCache.timestamp < SESSION_CACHE_MS) {
    return sessionCache.value
  }
  const res = await fetch(`${API_BASE}/api/sessions/me`, { credentials: 'include' })
  let value
  if (res.status === 401) value = null
  else if (!res.ok) throw new Error(`HTTP ${res.status}`)
  else value = await res.json()
  sessionCache.value = value
  sessionCache.timestamp = Date.now()
  return value
}

export async function login(username, password) {
  const res = await fetch(`${API_BASE}/api/sessions`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    credentials: 'include',
    body: JSON.stringify({ username, password }),
  })
  if (res.status === 401) throw new Error('Invalid credentials')
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  sessionCache.value = undefined
  sessionCache.timestamp = 0
  return await res.json()
}

export async function logout() {
  await fetch(`${API_BASE}/api/sessions`, {
    method: 'DELETE',
    credentials: 'include',
  })
  sessionCache.value = undefined
  sessionCache.timestamp = 0
}

export async function uploadVideo(username, { title, description, file, tags = [] }) {
  const fd = new FormData()
  fd.append('title', title)
  fd.append('description', description || '')
  fd.append('tags', tags.join(','))
  fd.append('file', file)

  const res = await fetch(`${API_BASE}/users/${encodeURIComponent(username)}/videos`, {
    method: 'POST',
    credentials: 'include',
    body: fd,
  })
  const body = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(body.error || `HTTP ${res.status}`)
  return body
}

export async function getProfile(username) {
  const res = await fetch(
    `${API_BASE}/api/users/${encodeURIComponent(username)}/profile`,
    { credentials: 'include' }
  )
  if (res.status === 404) return null
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return await res.json()
}

export async function follow(username, actorId) {
  const res = await fetch(
    `${API_BASE}/api/users/${encodeURIComponent(username)}/following`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'include',
      body: JSON.stringify({ actor: actorId }),
    }
  )
  const body = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(body.error || `HTTP ${res.status}`)
  return body
}

export async function unfollow(username, actorId) {
  const res = await fetch(
    `${API_BASE}/api/users/${encodeURIComponent(username)}/following`,
    {
      method: 'DELETE',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'include',
      body: JSON.stringify({ actor: actorId }),
    }
  )
  const body = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(body.error || `HTTP ${res.status}`)
  return body
}

export async function getNotifications(username) {
  const res = await fetch(
    `${API_BASE}/api/users/${encodeURIComponent(username)}/notifications`,
    { credentials: 'include' }
  )
  if (res.status === 401) throw new Error('Not logged in')
  if (res.status === 404) return { totalItems: 0, unseen: 0, items: [] }
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return await res.json()
}

export async function markNotificationsSeen(username) {
  const res = await fetch(
    `${API_BASE}/api/users/${encodeURIComponent(username)}/notifications/seen`,
    { method: 'POST', credentials: 'include' }
  )
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return await res.json()
}

export async function listComments(username, videoId) {
  const res = await fetch(
    `${API_BASE}/api/users/${encodeURIComponent(username)}/videos/${videoId}/comments`
  )
  if (res.status === 404) return { totalItems: 0, items: [] }
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return await res.json()
}

export async function postComment(username, videoId, body) {
  const res = await fetch(
    `${API_BASE}/api/users/${encodeURIComponent(username)}/videos/${videoId}/comments`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'include',
      body: JSON.stringify({ body }),
    }
  )
  const data = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`)
  return data
}

export async function deleteComment(username, videoId, commentId) {
  const res = await fetch(
    `${API_BASE}/api/users/${encodeURIComponent(username)}/videos/${videoId}/comments/${commentId}`,
    { method: 'DELETE', credentials: 'include' }
  )
  const data = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`)
  return data
}

export async function sendMessage(from, to, body) {
  const res = await fetch(`${API_BASE}/api/messages`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    credentials: 'include',
    body: JSON.stringify({ from, to, body }),
  })
  const data = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`)
  return data
}

export async function listInbox() {
  const res = await fetch(`${API_BASE}/api/messages/inbox`, { credentials: 'include' })
  if (res.status === 401) throw new Error('Not logged in')
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return await res.json()
}

export async function listThread(username) {
  const res = await fetch(
    `${API_BASE}/api/messages/thread/${encodeURIComponent(username)}`,
    { credentials: 'include' }
  )
  if (res.status === 401) throw new Error('Not logged in')
  if (res.status === 404) return { totalItems: 0, items: [] }
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return await res.json()
}

export async function markThreadRead(username) {
  const res = await fetch(
    `${API_BASE}/api/messages/thread/${encodeURIComponent(username)}/read`,
    { method: 'POST', credentials: 'include' }
  )
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return await res.json()
}

export async function search(q, type = 'all', limit = 20) {
  const params = new URLSearchParams({ q, type, limit: String(limit) })
  const res = await fetch(`${API_BASE}/api/search?${params}`)
  if (res.status === 400) throw new Error('Query too short or invalid')
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return await res.json()
}

export async function likeVideo(username, videoId) {
  const res = await fetch(
    `${API_BASE}/api/users/${encodeURIComponent(username)}/videos/${videoId}/like`,
    { method: 'POST', credentials: 'include' }
  )
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return await res.json()
}

export async function unlikeVideo(username, videoId) {
  const res = await fetch(
    `${API_BASE}/api/users/${encodeURIComponent(username)}/videos/${videoId}/like`,
    { method: 'DELETE', credentials: 'include' }
  )
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return await res.json()
}

export async function likeStatus(username, videoId) {
  const res = await fetch(
    `${API_BASE}/api/users/${encodeURIComponent(username)}/videos/${videoId}/like`,
    { credentials: 'include' }
  )
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return await res.json()
}

export async function boost(username, objectUrl) {
  const res = await fetch(
    `${API_BASE}/api/users/${encodeURIComponent(username)}/announces`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'include',
      body: JSON.stringify({ object: objectUrl }),
    }
  )
  const data = await res.json().catch(() => ({}))
  if (!res.ok && res.status !== 409) throw new Error(data.error || `HTTP ${res.status}`)
  return data
}

export async function unboost(username, objectUrl) {
  // Find the announce id first
  const list = await fetch(
    `${API_BASE}/api/users/${encodeURIComponent(username)}/announces`,
    { credentials: 'include' }
  ).then(r => r.json())

  const match = (list.items || []).find(a => a.object === objectUrl)
  if (!match) return { ok: 1 }

  const res = await fetch(
    `${API_BASE}/api/users/${encodeURIComponent(username)}/announces/${match.id}`,
    { method: 'DELETE', credentials: 'include' }
  )
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return await res.json()
}

export async function listConversations() {
  const res = await fetch(`${API_BASE}/api/messages/conversations`, {
    credentials: 'include',
  })
  if (res.status === 401) throw new Error('Not logged in')
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return await res.json()
}

export async function listFollowers(username) {
  const res = await fetch(`${API_BASE}/api/users/${encodeURIComponent(username)}/followers`)
  if (res.status === 404) return { totalItems: 0, items: [] }
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return await res.json()
}

export async function listFollowing(username) {
  const res = await fetch(`${API_BASE}/api/users/${encodeURIComponent(username)}/following`)
  if (res.status === 404) return { totalItems: 0, items: [] }
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return await res.json()
}

export async function followHandle(username, handle) {
  const res = await fetch(
    `${API_BASE}/api/users/${encodeURIComponent(username)}/following`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'include',
      body: JSON.stringify({ actor: handle }),
    }
  )
  const data = await res.json().catch(() => ({}))
  if (!res.ok && res.status !== 409) throw new Error(data.error || data.detail || `HTTP ${res.status}`)
  return data
}

export async function updateVideo(username, videoId, fields) {
  const res = await fetch(
    `${API_BASE}/api/users/${encodeURIComponent(username)}/videos/${videoId}`,
    {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'include',
      body: JSON.stringify(fields),
    }
  )
  const data = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`)
  return data
}

export async function deleteVideo(username, videoId) {
  const res = await fetch(
    `${API_BASE}/api/users/${encodeURIComponent(username)}/videos/${videoId}`,
    { method: 'DELETE', credentials: 'include' }
  )
  const data = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`)
  return data
}

export async function deleteAccount(username) {
  const res = await fetch(
    `${API_BASE}/api/users/${encodeURIComponent(username)}`,
    { method: 'DELETE', credentials: 'include' }
  )
  const data = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`)
  return data
}

export async function changePassword(username, oldPassword, newPassword) {
  const res = await fetch(
    `${API_BASE}/api/users/${encodeURIComponent(username)}/password`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'include',
      body: JSON.stringify({ old_password: oldPassword, new_password: newPassword }),
    }
  )
  const data = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(data.detail || data.error || `HTTP ${res.status}`)
  return data
}

export async function adminTables(token) {
  const res = await fetch(`${API_BASE}/api/admin/tables`, {
    headers: { 'X-Admin-Token': token },
  })
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return await res.json()
}

export async function adminTable(token, name, limit = 50, offset = 0) {
  const params = new URLSearchParams({ limit: String(limit), offset: String(offset) })
  const res = await fetch(`${API_BASE}/api/admin/table/${encodeURIComponent(name)}?${params}`, {
    headers: { 'X-Admin-Token': token },
  })
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return await res.json()
}

export async function adminWorkers(token) {
  const res = await fetch(`${API_BASE}/api/admin/workers`, {
    headers: { 'X-Admin-Token': token },
  })
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return await res.json()
}

export async function getRemoteVideo(id) {
  const res = await fetch(`${API_BASE}/api/remote-videos/${encodeURIComponent(id)}`)
  if (res.status === 404) return null
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return await res.json()
}

export async function listRemoteComments(id) {
  const res = await fetch(`${API_BASE}/api/remote-videos/${encodeURIComponent(id)}/comments`)
  if (res.status === 404) return { totalItems: 0, items: [] }
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return await res.json()
}

export async function postRemoteComment(id, body) {
  const res = await fetch(
    `${API_BASE}/api/remote-videos/${encodeURIComponent(id)}/comments`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'include',
      body: JSON.stringify({ body }),
    }
  )
  const data = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`)
  return data
}

export async function getRemoteActor(handle) {
  const res = await fetch(`${API_BASE}/api/remote-actors/${encodeURIComponent(handle)}`)
  if (res.status === 404) return null
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return await res.json()
}

export async function getInstance() {
  const res = await fetch(`${API_BASE}/api/instance`)
  if (!res.ok) return { name: 'FediVid', description: '' }
  return await res.json()
}

export async function uploadAvatar(username, file) {
  const fd = new FormData()
  fd.append('avatar', file)
  const res = await fetch(
    `${API_BASE}/api/users/${encodeURIComponent(username)}/avatar`,
    { method: 'POST', credentials: 'include', body: fd }
  )
  const data = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`)
  return data
}

export async function deleteAvatar(username) {
  const res = await fetch(
    `${API_BASE}/api/users/${encodeURIComponent(username)}/avatar`,
    { method: 'DELETE', credentials: 'include' }
  )
  const data = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`)
  return data
}

export async function getInstanceAbout() {
  const res = await fetch(`${API_BASE}/api/instance/about`)
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return await res.json()
}

export function openMessageSocket(onMessage, onHello) {
  const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
  const url = `${proto}//${window.location.host}/api/ws/messages`
  const ws = new WebSocket(url)

  ws.onmessage = (event) => {
    try {
      const data = JSON.parse(event.data)
      if (data.type === 'hello' && onHello) onHello(data)
      else if (data.type === 'message' && onMessage) onMessage(data)
    } catch { /* ignore */ }
  }

  return ws
}

export async function deleteThread(username) {
  const res = await fetch(
    `${API_BASE}/api/messages/thread/${encodeURIComponent(username)}`,
    { method: 'DELETE', credentials: 'include' }
  )
  const data = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`)
  return data
}

export async function deleteMessage(id) {
  const res = await fetch(
    `${API_BASE}/api/messages/${id}`,
    { method: 'DELETE', credentials: 'include' }
  )
  const data = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`)
  return data
}
