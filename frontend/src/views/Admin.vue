<script setup>
import { ref, onMounted, computed, watch } from 'vue'

const token = ref(sessionStorage.getItem('admin_token') || '')
const authed = ref(!!token.value)

const tab = ref('overview')

// Users
const users = ref([])
const usersTotal = ref(0)
const usersSearch = ref('')
const usersOffset = ref(0)
const usersLimit = 50
const usersSort = ref('created_at')
const usersDir = ref('asc')
const usersHasMore = ref(false)
const usersLoading = ref(false)
let userSearchTimer = null

// Overview
const health = ref(null)
const workers = ref(null)

// Tables
const tables = ref([])
const selectedTable = ref(null)
const tableData = ref(null)
const tableLimit = ref(30)
const tableOffset = ref(0)
const expandedRow = ref(null)

// Failures
const failures = ref([])
const failuresTotal = ref(0)
const failuresSearch = ref('')
const failuresOffset = ref(0)
const failuresLimit = 50
const failuresHasMore = ref(false)
const failuresLoading = ref(false)
const expandedFailure = ref(null)
const failureRows = ref({})
const failureRowsLoading = ref(false)
let failureSearchTimer = null

const loading = ref(false)
const error = ref(null)
const busyUser = ref(null)
let pollTimer = null

function saveToken() {
  sessionStorage.setItem('admin_token', token.value)
  authed.value = true
  refreshAll()
}

function clearToken() {
  sessionStorage.removeItem('admin_token')
  token.value = ''
  authed.value = false
  users.value = []
  health.value = null
  workers.value = null
  tables.value = []
  tableData.value = null
  selectedTable.value = null
  failures.value = []
  failuresTotal.value = 0
  expandedFailure.value = null
  failureRows.value = {}
  stopPolling()
}

async function api(path, opts = {}) {
  const res = await fetch(path, {
    ...opts,
    headers: {
      ...(opts.headers || {}),
      'X-Admin-Token': token.value,
    },
  })
  if (res.status === 403) throw new Error('Invalid admin token')
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  return await res.json()
}

async function refreshAll() {
  loading.value = true
  error.value = null
  try {
    const [h, w, t] = await Promise.all([
      api('/api/admin/health'),
      api('/api/admin/workers'),
      api('/api/admin/tables'),
    ])
    health.value = h
    workers.value = w
    tables.value = t.items || []
    if (tab.value === 'users') await loadUsers()
    else if (tab.value === 'failures') await loadFailures()
  } catch (e) {
    error.value = e.message
    if (e.message.includes('Invalid admin token')) clearToken()
  } finally {
    loading.value = false
  }
}

// ---------- Users ----------
async function loadUsers() {
  usersLoading.value = true
  error.value = null
  try {
    const params = new URLSearchParams({
      limit:  String(usersLimit),
      offset: String(usersOffset.value),
      sort:   usersSort.value,
      dir:    usersDir.value,
    })
    if (usersSearch.value) params.set('search', usersSearch.value)

    const data = await api(`/api/admin/users?${params}`)
    users.value       = data.items || []
    usersTotal.value  = data.totalItems + 0
    usersHasMore.value = data.has_more === 1
  } catch (e) {
    error.value = e.message
  } finally {
    usersLoading.value = false
  }
}

function onUserSearchInput() {
  clearTimeout(userSearchTimer)
  userSearchTimer = setTimeout(() => {
    usersOffset.value = 0
    loadUsers()
  }, 250)
}

function usersNext() {
  if (!usersHasMore.value) return
  usersOffset.value += usersLimit
  loadUsers()
}

function usersPrev() {
  if (usersOffset.value === 0) return
  usersOffset.value = Math.max(0, usersOffset.value - usersLimit)
  loadUsers()
}

function usersSortBy(col) {
  if (usersSort.value === col) {
    usersDir.value = usersDir.value === 'asc' ? 'desc' : 'asc'
  } else {
    usersSort.value = col
    usersDir.value  = 'asc'
  }
  usersOffset.value = 0
  loadUsers()
}

function sortArrow(col) {
  if (usersSort.value !== col) return ''
  return usersDir.value === 'asc' ? ' ↑' : ' ↓'
}

const usersPage = computed(() =>
  Math.floor(usersOffset.value / usersLimit) + 1
)
const usersPageCount = computed(() =>
  Math.max(1, Math.ceil(usersTotal.value / usersLimit))
)

async function deleteUser(username) {
  if (!confirm(`Delete user "${username}"? This removes all their videos, comments, and messages. This cannot be undone.`)) return
  busyUser.value = username
  try {
    await api(`/api/admin/users/${username}`, { method: 'DELETE' })
    await loadUsers()
  } catch (e) {
    error.value = e.message
  } finally {
    busyUser.value = null
  }
}

async function disableUser(username) {
  if (!confirm(`Disable account "${username}"? They won't be able to log in.`)) return
  busyUser.value = username
  try {
    await api(`/api/admin/users/${username}/disable`, { method: 'POST' })
    await loadUsers()
  } catch (e) {
    error.value = e.message
  } finally {
    busyUser.value = null
  }
}

async function enableUser(username) {
  busyUser.value = username
  try {
    await api(`/api/admin/users/${username}/enable`, { method: 'POST' })
    await loadUsers()
  } catch (e) {
    error.value = e.message
  } finally {
    busyUser.value = null
  }
}

// ---------- Tables ----------
async function openTable(name) {
  selectedTable.value = name
  tableOffset.value = 0
  expandedRow.value = null
  await loadTable()
}

async function loadTable() {
  if (!selectedTable.value) return
  loading.value = true
  error.value = null
  try {
    tableData.value = await api(
      `/api/admin/table/${encodeURIComponent(selectedTable.value)}?limit=${tableLimit.value}&offset=${tableOffset.value}`
    )
  } catch (e) {
    error.value = e.message
  } finally {
    loading.value = false
  }
}

function nextPage() {
  if (tableData.value.has_more) {
    tableOffset.value = tableData.value.next_offset
    expandedRow.value = null
    loadTable()
  }
}

function prevPage() {
  if (tableOffset.value > 0) {
    tableOffset.value = Math.max(0, tableOffset.value - tableLimit.value)
    expandedRow.value = null
    loadTable()
  }
}

function toggleRow(i) {
  expandedRow.value = expandedRow.value === i ? null : i
}

// ---------- Failures ----------
async function loadFailures() {
  failuresLoading.value = true
  error.value = null
  try {
    const params = new URLSearchParams({
      limit:  String(failuresLimit),
      offset: String(failuresOffset.value),
    })
    if (failuresSearch.value) params.set('search', failuresSearch.value)

    const data = await api(`/api/admin/failures?${params}`)
    failures.value       = data.items || []
    failuresTotal.value  = data.totalItems + 0
    failuresHasMore.value = data.has_more === 1
  } catch (e) {
    error.value = e.message
  } finally {
    failuresLoading.value = false
  }
}

function onFailureSearchInput() {
  clearTimeout(failureSearchTimer)
  failureSearchTimer = setTimeout(() => {
    failuresOffset.value = 0
    expandedFailure.value = null
    failureRows.value = {}
    loadFailures()
  }, 250)
}

function failuresNext() {
  if (!failuresHasMore.value) return
  failuresOffset.value += failuresLimit
  loadFailures()
}

function failuresPrev() {
  if (failuresOffset.value === 0) return
  failuresOffset.value = Math.max(0, failuresOffset.value - failuresLimit)
  loadFailures()
}

async function toggleFailure(i) {
  if (expandedFailure.value === i) {
    expandedFailure.value = null
    return
  }
  expandedFailure.value = i

  if (!failureRows.value[i]) {
    failureRowsLoading.value = true
    try {
      const f = failures.value[i]
      const data = await api(
        `/api/admin/failure-rows?inbox_url=${encodeURIComponent(f.inbox_url)}&last_error=${encodeURIComponent(f.last_error)}&limit=100`
      )
      failureRows.value = { ...failureRows.value, [i]: data.items || [] }
    } catch (e) {
      error.value = e.message
    } finally {
      failureRowsLoading.value = false
    }
  }
}

const failuresPage = computed(() =>
  Math.floor(failuresOffset.value / failuresLimit) + 1
)
const failuresPageCount = computed(() =>
  Math.max(1, Math.ceil(failuresTotal.value / failuresLimit))
)

// ---------- Shared ----------
function fmtRel(ts) {
  if (!ts) return '—'
  const diff = (Date.now() - new Date(ts).getTime()) / 1000
  if (diff < 60) return 'just now'
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`
  if (diff < 86400 * 7) return `${Math.floor(diff / 86400)}d ago`
  return new Date(ts).toLocaleDateString()
}

const tableColumns = computed(() => {
  if (!tableData.value || !tableData.value.items.length) return []
  const keys = Object.keys(tableData.value.items[0])
  const idx = keys.indexOf('id')
  if (idx > 0) {
    keys.splice(idx, 1)
    keys.unshift('id')
  }
  return keys
})

function isTimestampKey(k) {
  return /_at$|^created|^published|^scheduled|^completed|^expires/.test(k)
}

function isJsonKey(k) {
  return k === 'activity' || k === 'actor'
}

const workerCards = computed(() => {
  if (!workers.value) return []
  return [
    { key: 'delivery', label: 'Delivery worker', data: workers.value.delivery },
    { key: 'transcode', label: 'Transcode worker', data: workers.value.transcode },
  ]
})

function statusVariant(status) {
  return {
    active: 'success',
    idle:   'warning',
    slow:   'warning',
    dead:   'danger',
    never:  '',
  }[status] || ''
}

function startPolling() {
  stopPolling()
  pollTimer = setInterval(() => {
    if (!authed.value) return
    if (tab.value === 'overview') refreshAll()
  }, 30_000)
}

function stopPolling() {
  if (pollTimer) { clearInterval(pollTimer); pollTimer = null }
}

watch(tab, (t) => {
  if (!authed.value) return
  if (t === 'users' && users.value.length === 0) loadUsers()
  else if (t === 'failures' && failures.value.length === 0) loadFailures()
})

onMounted(() => {
  if (authed.value) {
    refreshAll()
    startPolling()
  }
})
</script>

<template>
  <div class="stack">

    <template v-if="!authed">
      <div>
        <h1>Admin</h1>
        <p class="muted">Enter the admin token to access this panel.</p>
      </div>

      <div class="card" style="max-width: 24rem;">
        <label class="label-text" for="admin-token">Admin token</label>
        <input
          id="admin-token"
          v-model="token"
          type="password"
          placeholder="X-Admin-Token value"
          @keyup.enter="saveToken"
        />
        <button
          class="btn btn-primary"
          style="width: 100%; margin-top: 1rem;"
          :disabled="!token"
          @click="saveToken"
        >Unlock</button>
      </div>
    </template>

    <template v-else>
      <div style="display:flex; align-items:center; justify-content:space-between; gap:1rem; flex-wrap:wrap;">
        <div>
          <h1>Admin</h1>
          <p class="muted" style="margin: 0;">Instance overview, failures, users, and database browser.</p>
        </div>
        <div style="display: flex; gap: 0.5rem;">
          <button class="btn" :disabled="loading" @click="refreshAll">
            {{ loading ? 'Refreshing…' : 'Refresh' }}
          </button>
          <button class="btn btn-ghost" @click="clearToken">Lock</button>
        </div>
      </div>

      <p v-if="error" class="error">{{ error }}</p>

      <!-- Tabs -->
      <div style="display:flex; gap:0.25rem; border-bottom:1px solid #232833; margin-bottom:1.25rem;">
        <button
          :style="{
            padding: '0.65rem 1rem',
            background: 'transparent',
            border: 0,
            borderBottom: tab === 'overview' ? '2px solid #8b5cf6' : '2px solid transparent',
            color: tab === 'overview' ? '#f4f4f7' : '#6a7180',
            fontFamily: 'inherit',
            fontSize: '0.9rem',
            fontWeight: 600,
            cursor: 'pointer',
          }"
          @click="tab = 'overview'"
        >Overview</button>
        <button
          :style="{
            padding: '0.65rem 1rem',
            background: 'transparent',
            border: 0,
            borderBottom: tab === 'failures' ? '2px solid #8b5cf6' : '2px solid transparent',
            color: tab === 'failures' ? '#f4f4f7' : '#6a7180',
            fontFamily: 'inherit',
            fontSize: '0.9rem',
            fontWeight: 600,
            cursor: 'pointer',
            display: 'inline-flex',
            alignItems: 'center',
            gap: '0.5rem',
          }"
          @click="tab = 'failures'"
        >
          Failures
          <span
            v-if="health && health.deliveries.failed > 0"
            :style="{
              display: 'inline-block',
              minWidth: '22px',
              padding: '0.1rem 0.45rem',
              background: 'rgba(239, 68, 68, 0.15)',
              color: '#ef4444',
              borderRadius: '9999px',
              fontSize: '0.72rem',
              fontWeight: 700,
              textAlign: 'center',
              lineHeight: '1.4',
            }"
          >{{ health.deliveries.failed }}</span>
        </button>
        <button
          :style="{
            padding: '0.65rem 1rem',
            background: 'transparent',
            border: 0,
            borderBottom: tab === 'users' ? '2px solid #8b5cf6' : '2px solid transparent',
            color: tab === 'users' ? '#f4f4f7' : '#6a7180',
            fontFamily: 'inherit',
            fontSize: '0.9rem',
            fontWeight: 600,
            cursor: 'pointer',
          }"
          @click="tab = 'users'"
        >Users</button>
        <button
          :style="{
            padding: '0.65rem 1rem',
            background: 'transparent',
            border: 0,
            borderBottom: tab === 'tables' ? '2px solid #8b5cf6' : '2px solid transparent',
            color: tab === 'tables' ? '#f4f4f7' : '#6a7180',
            fontFamily: 'inherit',
            fontSize: '0.9rem',
            fontWeight: 600,
            cursor: 'pointer',
          }"
          @click="tab = 'tables'"
        >Tables</button>
      </div>

      <!-- ================= OVERVIEW ================= -->
      <template v-if="tab === 'overview'">
        <div style="display:grid; grid-template-columns:repeat(auto-fit, minmax(280px, 1fr)); gap:0.75rem;">
          <div
            v-for="w in workerCards"
            :key="w.key"
            style="padding:1.1rem 1.25rem; background:#14171f; border:1px solid #232833; border-radius:14px;"
          >
            <div style="display:flex; align-items:flex-start; justify-content:space-between; gap:0.5rem; margin-bottom:0.9rem;">
              <div>
                <div style="font-weight:700; font-size:0.95rem;">{{ w.label }}</div>
                <div style="color:#6a7180; font-size:0.8rem; margin-top:0.15rem;">{{ w.data.message }}</div>
              </div>
              <span class="badge" :class="`badge-${statusVariant(w.data.status)}`">{{ w.data.status }}</span>
            </div>

            <div style="display:flex; gap:1.5rem;">
              <div>
                <div style="font-size:0.7rem; text-transform:uppercase; letter-spacing:0.05em; color:#6a7180; font-weight:600;">Last seen</div>
                <div style="font-weight:700; font-size:0.95rem;">{{ w.data.last_seen ? fmtRel(w.data.last_seen) : '—' }}</div>
              </div>
              <div>
                <div style="font-size:0.7rem; text-transform:uppercase; letter-spacing:0.05em; color:#6a7180; font-weight:600;">Pending</div>
                <div style="font-weight:700; font-size:0.95rem;">{{ w.data.pending_count }}</div>
              </div>
              <div>
                <div style="font-size:0.7rem; text-transform:uppercase; letter-spacing:0.05em; color:#6a7180; font-weight:600;">Processed</div>
                <div style="font-weight:700; font-size:0.95rem;">{{ w.data.processed }}</div>
              </div>
            </div>
          </div>
        </div>

        <div v-if="health" style="display:grid; grid-template-columns:repeat(auto-fit, minmax(150px, 1fr)); gap:0.6rem;">
          <div style="padding:0.9rem 1rem; background:#14171f; border:1px solid #232833; border-radius:12px;">
            <div style="font-size:1.5rem; font-weight:800; letter-spacing:-0.02em; line-height:1; margin-bottom:0.25rem;">{{ health.deliveries.failed }}</div>
            <div style="font-size:0.72rem; text-transform:uppercase; letter-spacing:0.05em; color:#6a7180; font-weight:600;">Delivery failures</div>
          </div>
          <div style="padding:0.9rem 1rem; background:#14171f; border:1px solid #232833; border-radius:12px;">
            <div style="font-size:1.5rem; font-weight:800; letter-spacing:-0.02em; line-height:1; margin-bottom:0.25rem;">{{ health.deliveries.pending }}</div>
            <div style="font-size:0.72rem; text-transform:uppercase; letter-spacing:0.05em; color:#6a7180; font-weight:600;">Deliveries pending</div>
          </div>
          <div style="padding:0.9rem 1rem; background:#14171f; border:1px solid #232833; border-radius:12px;">
            <div :style="{ fontSize: '1.5rem', fontWeight: 800, letterSpacing: '-0.02em', lineHeight: 1, marginBottom: '0.25rem', color: health.videos.transcode_failed > 0 ? '#ef4444' : 'inherit' }">{{ health.videos.transcode_failed }}</div>
            <div style="font-size:0.72rem; text-transform:uppercase; letter-spacing:0.05em; color:#6a7180; font-weight:600;">Transcode failures</div>
          </div>
          <div style="padding:0.9rem 1rem; background:#14171f; border:1px solid #232833; border-radius:12px;">
            <div style="font-size:1.5rem; font-weight:800; letter-spacing:-0.02em; line-height:1; margin-bottom:0.25rem;">{{ health.remote_actors }}</div>
            <div style="font-size:0.72rem; text-transform:uppercase; letter-spacing:0.05em; color:#6a7180; font-weight:600;">Remote actors</div>
          </div>
        </div>
      </template>

      <!-- ================= FAILURES ================= -->
      <template v-if="tab === 'failures'">
        <div style="display:flex; align-items:center; justify-content:space-between; gap:1rem; flex-wrap:wrap; margin-bottom:1rem;">
          <div>
            <h2 style="margin: 0;">Delivery failures</h2>
            <p class="muted" style="margin: 0.15rem 0 0; font-size: 0.85rem;">
              {{ failuresTotal }} group{{ failuresTotal === 1 ? '' : 's' }}
            </p>
          </div>
          <input
            v-model="failuresSearch"
            type="search"
            placeholder="Search inbox, error, or user…"
            @input="onFailureSearchInput"
            style="width:280px; padding:0.5rem 0.85rem; font-size:0.88rem;"
          />
        </div>

        <!-- FIXED TABLE — inline styles, no scoped CSS -->
        <div style="background:#14171f; border:1px solid #232833; border-radius:12px; overflow-x:auto;">
          <table style="width:100%; border-collapse:collapse; table-layout:fixed; font-size:0.85rem;">
            <colgroup>
              <col style="width: 30%;" />
              <col style="width: 36%;" />
              <col style="width: 10%;" />
              <col style="width: 10%;" />
              <col style="width: 14%;" />
            </colgroup>
            <thead>
              <tr>
                <th style="text-align:left; padding:0.7rem 0.85rem; font-size:0.72rem; text-transform:uppercase; letter-spacing:0.05em; color:#6a7180; font-weight:600; border-bottom:1px solid #232833; background:#191c26;">Inbox</th>
                <th style="text-align:left; padding:0.7rem 0.85rem; font-size:0.72rem; text-transform:uppercase; letter-spacing:0.05em; color:#6a7180; font-weight:600; border-bottom:1px solid #232833; background:#191c26;">Error</th>
                <th style="text-align:right; padding:0.7rem 0.85rem; font-size:0.72rem; text-transform:uppercase; letter-spacing:0.05em; color:#6a7180; font-weight:600; border-bottom:1px solid #232833; background:#191c26;">Count</th>
                <th style="text-align:right; padding:0.7rem 0.85rem; font-size:0.72rem; text-transform:uppercase; letter-spacing:0.05em; color:#6a7180; font-weight:600; border-bottom:1px solid #232833; background:#191c26;">Attempts</th>
                <th style="text-align:left; padding:0.7rem 0.85rem; font-size:0.72rem; text-transform:uppercase; letter-spacing:0.05em; color:#6a7180; font-weight:600; border-bottom:1px solid #232833; background:#191c26;">Last seen</th>
              </tr>
            </thead>
            <tbody>
              <template v-for="(f, i) in failures" :key="i">
                <tr
                  style="cursor:pointer; border-bottom:1px solid #232833;"
                  @click="toggleFailure(i)"
                >
                  <td style="padding:0.7rem 0.85rem; vertical-align:top; color:#a1a7b3; font-family:ui-monospace, monospace; font-size:0.78rem; line-height:1.35; word-break:break-all;">{{ f.inbox_url }}</td>
                  <td style="padding:0.7rem 0.85rem; vertical-align:top; color:#ef4444; font-size:0.85rem; line-height:1.35; word-break:break-word;">{{ f.last_error }}</td>
                  <td style="padding:0.7rem 0.85rem; vertical-align:top; text-align:right;">
                    <span class="badge badge-danger">{{ f.count }}</span>
                  </td>
                  <td style="padding:0.7rem 0.85rem; vertical-align:top; text-align:right;">
                    <span class="badge">{{ f.max_attempts }}</span>
                  </td>
                  <td style="padding:0.7rem 0.85rem; vertical-align:top; color:#6a7180; font-size:0.82rem;">{{ fmtRel(f.last_at) }}</td>
                </tr>
                <tr v-if="expandedFailure === i">
                  <td colspan="5" style="padding:0; border-bottom:1px solid #232833;">
                    <div style="padding:0.9rem 1rem; background:#191c26;">
                      <div v-if="failureRowsLoading" class="muted">Loading individual rows…</div>
                      <div v-else-if="!failureRows[i] || failureRows[i].length === 0" class="muted">
                        No individual rows available.
                      </div>
                      <table v-else style="width:100%; border-collapse:collapse; font-size:0.8rem;">
                        <thead>
                          <tr>
                            <th style="text-align:left; padding:0.45rem 0.7rem; color:#6a7180; font-weight:600; font-size:0.72rem; text-transform:uppercase; border-bottom:1px solid #232833;">ID</th>
                            <th style="text-align:left; padding:0.45rem 0.7rem; color:#6a7180; font-weight:600; font-size:0.72rem; text-transform:uppercase; border-bottom:1px solid #232833;">User</th>
                            <th style="text-align:left; padding:0.45rem 0.7rem; color:#6a7180; font-weight:600; font-size:0.72rem; text-transform:uppercase; border-bottom:1px solid #232833;">Activity</th>
                            <th style="text-align:right; padding:0.45rem 0.7rem; color:#6a7180; font-weight:600; font-size:0.72rem; text-transform:uppercase; border-bottom:1px solid #232833;">Attempts</th>
                            <th style="text-align:left; padding:0.45rem 0.7rem; color:#6a7180; font-weight:600; font-size:0.72rem; text-transform:uppercase; border-bottom:1px solid #232833;">When</th>
                          </tr>
                        </thead>
                        <tbody>
                          <tr v-for="r in failureRows[i]" :key="r.id">
                            <td style="padding:0.45rem 0.7rem; border-bottom:1px solid #232833;">
                              <span class="id-badge">{{ r.id }}</span>
                            </td>
                            <td style="padding:0.45rem 0.7rem; border-bottom:1px solid #232833;">@{{ r.username }}</td>
                            <td style="padding:0.45rem 0.7rem; border-bottom:1px solid #232833; font-family:ui-monospace, monospace; font-size:0.78rem; word-break:break-all;">{{ r.activity_id }}</td>
                            <td style="padding:0.45rem 0.7rem; border-bottom:1px solid #232833; text-align:right;">{{ r.attempts }}</td>
                            <td style="padding:0.45rem 0.7rem; border-bottom:1px solid #232833; color:#6a7180;">{{ fmtRel(r.scheduled_at) }}</td>
                          </tr>
                        </tbody>
                      </table>
                    </div>
                  </td>
                </tr>
              </template>
              <tr v-if="failures.length === 0 && !failuresLoading">
                <td colspan="5" style="text-align:center; padding:2.5rem; color:#6a7180;">
                  <template v-if="failuresSearch">No failures match "{{ failuresSearch }}".</template>
                  <template v-else>No failures. 🎉</template>
                </td>
              </tr>
              <tr v-if="failuresLoading">
                <td colspan="5" style="text-align:center; padding:1rem; color:#6a7180;">Loading…</td>
              </tr>
            </tbody>
          </table>
        </div>

        <div v-if="failuresPageCount > 1" style="display:flex; justify-content:center; align-items:center; gap:0.5rem; margin-top:1rem; padding-top:1rem; border-top:1px solid #232833;">
          <button class="btn btn-sm" :disabled="failuresOffset === 0 || failuresLoading" @click="failuresPrev">← Prev</button>
          <span class="muted">Page {{ failuresPage }} / {{ failuresPageCount }}</span>
          <button class="btn btn-sm" :disabled="!failuresHasMore || failuresLoading" @click="failuresNext">Next →</button>
        </div>
      </template>

      <!-- ================= USERS ================= -->
      <template v-if="tab === 'users'">
        <div style="display:flex; align-items:center; justify-content:space-between; gap:1rem; flex-wrap:wrap; margin-bottom:1rem;">
          <div>
            <h2 style="margin: 0;">Users</h2>
            <p class="muted" style="margin: 0.15rem 0 0; font-size: 0.85rem;">
              {{ usersTotal }} user{{ usersTotal === 1 ? '' : 's' }}
            </p>
          </div>
          <input
            v-model="usersSearch"
            type="search"
            placeholder="Search username…"
            @input="onUserSearchInput"
            style="width:280px; padding:0.5rem 0.85rem; font-size:0.88rem;"
          />
        </div>

        <div style="background:#14171f; border:1px solid #232833; border-radius:12px; overflow-x:auto;">
          <table style="width:100%; border-collapse:collapse; font-size:0.85rem;">
            <thead>
              <tr>
                <th style="text-align:left; padding:0.7rem 0.85rem; font-size:0.72rem; text-transform:uppercase; letter-spacing:0.05em; color:#6a7180; font-weight:600; border-bottom:1px solid #232833; background:#191c26; cursor:pointer;" @click="usersSortBy('username')">Username{{ sortArrow('username') }}</th>
                <th style="text-align:left; padding:0.7rem 0.85rem; font-size:0.72rem; text-transform:uppercase; letter-spacing:0.05em; color:#6a7180; font-weight:600; border-bottom:1px solid #232833; background:#191c26;">Status</th>
                <th style="text-align:right; padding:0.7rem 0.85rem; font-size:0.72rem; text-transform:uppercase; letter-spacing:0.05em; color:#6a7180; font-weight:600; border-bottom:1px solid #232833; background:#191c26; cursor:pointer;" @click="usersSortBy('videos')">Videos{{ sortArrow('videos') }}</th>
                <th style="text-align:right; padding:0.7rem 0.85rem; font-size:0.72rem; text-transform:uppercase; letter-spacing:0.05em; color:#6a7180; font-weight:600; border-bottom:1px solid #232833; background:#191c26; cursor:pointer;" @click="usersSortBy('followers')">Followers{{ sortArrow('followers') }}</th>
                <th style="text-align:right; padding:0.7rem 0.85rem; font-size:0.72rem; text-transform:uppercase; letter-spacing:0.05em; color:#6a7180; font-weight:600; border-bottom:1px solid #232833; background:#191c26; cursor:pointer;" @click="usersSortBy('following')">Following{{ sortArrow('following') }}</th>
                <th style="text-align:right; padding:0.7rem 0.85rem; font-size:0.72rem; text-transform:uppercase; letter-spacing:0.05em; color:#6a7180; font-weight:600; border-bottom:1px solid #232833; background:#191c26;">Comments</th>
                <th style="text-align:left; padding:0.7rem 0.85rem; font-size:0.72rem; text-transform:uppercase; letter-spacing:0.05em; color:#6a7180; font-weight:600; border-bottom:1px solid #232833; background:#191c26; cursor:pointer;" @click="usersSortBy('created_at')">Created{{ sortArrow('created_at') }}</th>
                <th style="padding:0.7rem 0.85rem; border-bottom:1px solid #232833; background:#191c26;"></th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="u in users" :key="u.username" :style="{ borderBottom: '1px solid #232833', opacity: u.disabled ? 0.55 : 1 }">
                <td style="padding:0.7rem 0.85rem;">
                  <RouterLink :to="`/users/${u.username}`" style="color:#8b5cf6; font-weight:600; text-decoration:none;">@{{ u.username }}</RouterLink>
                </td>
                <td style="padding:0.7rem 0.85rem;">
                  <span v-if="u.disabled" class="badge badge-danger">disabled</span>
                  <span v-else class="badge badge-success">active</span>
                </td>
                <td style="padding:0.7rem 0.85rem; text-align:right;">{{ u.video_count }}</td>
                <td style="padding:0.7rem 0.85rem; text-align:right;">{{ u.followers_count }}</td>
                <td style="padding:0.7rem 0.85rem; text-align:right;">{{ u.following_count }}</td>
                <td style="padding:0.7rem 0.85rem; text-align:right;">{{ u.comment_count }}</td>
                <td style="padding:0.7rem 0.85rem; color:#6a7180;">{{ fmtRel(u.created_at) }}</td>
                <td style="padding:0.7rem 0.85rem; white-space:nowrap;">
                  <button
                    v-if="u.disabled"
                    class="btn btn-ghost btn-sm"
                    :disabled="busyUser === u.username"
                    @click="enableUser(u.username)"
                  >Enable</button>
                  <button
                    v-else
                    class="btn btn-ghost btn-sm"
                    :disabled="busyUser === u.username"
                    @click="disableUser(u.username)"
                  >Disable</button>

                  <button
                    class="btn btn-ghost btn-danger btn-sm"
                    style="margin-left:0.4rem;"
                    :disabled="busyUser === u.username"
                    @click="deleteUser(u.username)"
                  >Delete</button>
                </td>
              </tr>
              <tr v-if="users.length === 0 && !usersLoading">
                <td colspan="8" style="text-align:center; padding:2.5rem; color:#6a7180;">
                  <template v-if="usersSearch">No users match "{{ usersSearch }}".</template>
                  <template v-else>No users yet.</template>
                </td>
              </tr>
              <tr v-if="usersLoading">
                <td colspan="8" style="text-align:center; padding:1rem; color:#6a7180;">Loading…</td>
              </tr>
            </tbody>
          </table>
        </div>

        <div v-if="usersPageCount > 1" style="display:flex; justify-content:center; align-items:center; gap:0.5rem; margin-top:1rem; padding-top:1rem; border-top:1px solid #232833;">
          <button class="btn btn-sm" :disabled="usersOffset === 0 || usersLoading" @click="usersPrev">← Prev</button>
          <span class="muted">Page {{ usersPage }} / {{ usersPageCount }}</span>
          <button class="btn btn-sm" :disabled="!usersHasMore || usersLoading" @click="usersNext">Next →</button>
        </div>
      </template>

      <!-- ================= TABLES ================= -->
      <template v-if="tab === 'tables'">
        <div style="display:grid; grid-template-columns:220px 1fr; gap:1rem; align-items:start;">
          <aside style="display:flex; flex-direction:column; gap:0.15rem; max-height:70vh; overflow-y:auto; background:#14171f; border:1px solid #232833; border-radius:14px; padding:0.4rem;">
            <div
              v-for="t in tables"
              :key="t.name"
              :style="{
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'space-between',
                gap: '0.5rem',
                padding: '0.5rem 0.75rem',
                borderRadius: '8px',
                cursor: 'pointer',
                fontSize: '0.85rem',
                background: selectedTable === t.name ? '#8b5cf6' : 'transparent',
                color: selectedTable === t.name ? '#fff' : 'inherit',
              }"
              @click="openTable(t.name)"
            >
              <span style="overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-family:ui-monospace, monospace;">{{ t.name }}</span>
              <span :style="{ fontSize: '0.72rem', color: selectedTable === t.name ? 'rgba(255,255,255,0.75)' : '#6a7180', flexShrink: 0, fontWeight: 600 }">{{ t.count }}</span>
            </div>
          </aside>

          <div style="min-width:0;">
            <div v-if="!selectedTable" class="empty">
              Select a table on the left to browse its rows.
            </div>

            <template v-else-if="tableData">
              <div style="display:flex; align-items:center; justify-content:space-between; gap:1rem; flex-wrap:wrap; margin-bottom:0.75rem;">
                <div>
                  <div style="font-weight:700; font-size:1rem; font-family:ui-monospace, monospace;">{{ selectedTable }}</div>
                  <div class="muted" style="font-size:0.85rem;">{{ tableData.totalItems }} rows</div>
                </div>
                <div style="display:flex; align-items:center; gap:0.5rem;">
                  <button class="btn btn-sm" :disabled="tableOffset === 0 || loading" @click="prevPage">← Prev</button>
                  <button class="btn btn-sm" :disabled="!tableData.has_more || loading" @click="nextPage">Next →</button>
                </div>
              </div>

              <div style="background:#14171f; border:1px solid #232833; border-radius:12px; overflow-x:auto;">
                <table style="width:100%; border-collapse:collapse; font-size:0.8rem;">
                  <thead>
                    <tr>
                      <th v-for="c in tableColumns" :key="c" style="text-align:left; padding:0.45rem 0.7rem; font-size:0.72rem; text-transform:uppercase; letter-spacing:0.05em; color:#6a7180; font-weight:600; border-bottom:1px solid #232833; background:#191c26; font-family:ui-monospace, monospace;">{{ c }}</th>
                    </tr>
                  </thead>
                  <tbody>
                    <template v-for="(row, i) in tableData.items" :key="i">
                      <tr style="cursor:pointer; border-bottom:1px solid #232833;" @click="toggleRow(i)">
                        <td v-for="c in tableColumns" :key="c" style="padding:0.45rem 0.7rem; font-family:ui-monospace, monospace; max-width:260px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;">
                          <template v-if="c === 'id'"><span class="id-badge">{{ row[c] }}</span></template>
                          <template v-else-if="isTimestampKey(c) && row[c]">{{ fmtRel(row[c]) }}</template>
                          <template v-else-if="isJsonKey(c)"><span class="muted">{…}</span></template>
                          <template v-else-if="row[c] === null || row[c] === undefined"><span class="null">—</span></template>
                          <template v-else-if="String(row[c]).length > 60">{{ String(row[c]).slice(0, 60) }}…</template>
                          <template v-else>{{ row[c] }}</template>
                        </td>
                      </tr>
                      <tr v-if="expandedRow === i">
                        <td :colspan="tableColumns.length" style="padding:0; border-bottom:1px solid #232833;">
                          <div style="display:grid; grid-template-columns:180px 1fr; gap:0.4rem 1rem; padding:1rem 1.25rem; background:#191c26;">
                            <div v-for="c in tableColumns" :key="c" style="display:contents;">
                              <div style="font-size:0.75rem; text-transform:uppercase; letter-spacing:0.05em; color:#6a7180; font-weight:600; font-family:ui-monospace, monospace; padding-top:0.15rem;">{{ c }}</div>
                              <div style="color:#f4f4f7; font-size:0.85rem; word-break:break-word; white-space:pre-wrap; font-family:ui-monospace, monospace;">
                                <template v-if="isJsonKey(c) && row[c]">
                                  <pre style="margin:0; padding:0.5rem 0.75rem; background:#14171f; border:1px solid #232833; border-radius:8px; font-size:0.78rem; max-height:300px; overflow:auto; white-space:pre-wrap; word-break:break-all;">{{ JSON.stringify(row[c], null, 2) }}</pre>
                                </template>
                                <template v-else-if="row[c] === null || row[c] === undefined">
                                  <span class="null">null</span>
                                </template>
                                <template v-else>{{ row[c] }}</template>
                              </div>
                            </div>
                          </div>
                        </td>
                      </tr>
                    </template>
                    <tr v-if="tableData.items.length === 0">
                      <td :colspan="tableColumns.length" style="text-align:center; padding:2rem; color:#6a7180;">No rows.</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </template>
          </div>
        </div>
      </template>
    </template>
  </div>
</template>
