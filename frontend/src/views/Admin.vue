<script setup>
import { ref, onMounted, computed } from 'vue'

const token = ref(sessionStorage.getItem('admin_token') || '')
const authed = ref(!!token.value)

const tab = ref('overview')

const users = ref([])
const usersTotal = ref(0)
const usersSearch = ref('')
const usersOffset = ref(0)
const usersLimit = 50
const usersSort = ref('created_at')
const usersDir = ref('asc')
const usersHasMore = ref(false)
const usersLoading = ref(false)
let searchTimer = null

const health = ref(null)
const workers = ref(null)

const tables = ref([])
const selectedTable = ref(null)
const tableData = ref(null)
const tableLimit = ref(30)
const tableOffset = ref(0)
const expandedRow = ref(null)

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
    await loadUsers()
  } catch (e) {
    error.value = e.message
    if (e.message.includes('Invalid admin token')) clearToken()
  } finally {
    loading.value = false
  }
}

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

function onSearchInput() {
  clearTimeout(searchTimer)
  searchTimer = setTimeout(() => {
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

function fmtDate(ts) {
  if (!ts) return '—'
  return new Date(ts).toLocaleString()
}

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
  // id first if present
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
  return k === 'activity' || k === 'actor' || k === 'public_key'
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
    if (authed.value && tab.value === 'overview') refreshAll()
  }, 30_000)
}

function stopPolling() {
  if (pollTimer) { clearInterval(pollTimer); pollTimer = null }
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
      <div class="admin-header">
        <div>
          <h1>Admin</h1>
          <p class="muted" style="margin: 0;">Instance overview and database browser.</p>
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
      <div class="tabs">
        <button class="tab" :class="{ active: tab === 'overview' }" @click="tab = 'overview'">Overview</button>
        <button class="tab" :class="{ active: tab === 'tables' }" @click="tab = 'tables'">Tables</button>
      </div>

      <!-- OVERVIEW -->
      <template v-if="tab === 'overview'">

        <!-- Workers -->
        <div class="worker-grid">
          <div v-for="w in workerCards" :key="w.key" class="worker-card">
            <div class="worker-card-head">
              <div>
                <div class="worker-card-title">{{ w.label }}</div>
                <div class="worker-card-msg">{{ w.data.message }}</div>
              </div>
              <span class="badge" :class="`badge-${statusVariant(w.data.status)}`">
                {{ w.data.status }}
              </span>
            </div>

            <div class="worker-card-stats">
              <div>
                <div class="worker-stat-label">Last seen</div>
                <div class="worker-stat-value">
                  {{ w.data.last_seen ? fmtRel(w.data.last_seen) : '—' }}
                </div>
              </div>
              <div>
                <div class="worker-stat-label">Pending</div>
                <div class="worker-stat-value">{{ w.data.pending_count }}</div>
              </div>
              <div>
                <div class="worker-stat-label">Processed</div>
                <div class="worker-stat-value">{{ w.data.processed }}</div>
              </div>
            </div>
          </div>
        </div>

        <!-- Stat tiles -->
        <div v-if="health" class="stat-grid">
          <div class="stat-tile">
            <div class="stat-tile-value">{{ users.length }}</div>
            <div class="stat-tile-label">Users</div>
          </div>
          <div class="stat-tile">
            <div class="stat-tile-value">{{ health.remote_actors }}</div>
            <div class="stat-tile-label">Remote actors</div>
          </div>
          <div class="stat-tile">
            <div class="stat-tile-value" :class="{ bad: health.deliveries.failed > 0 }">
              {{ health.deliveries.failed }}
            </div>
            <div class="stat-tile-label">Delivery failures</div>
          </div>
          <div class="stat-tile">
            <div class="stat-tile-value" :class="{ bad: health.videos.transcode_failed > 0 }">
              {{ health.videos.transcode_failed }}
            </div>
            <div class="stat-tile-label">Transcode failures</div>
          </div>
        </div>

        <!-- Recent failures -->
        <section v-if="health && health.recent_failures.length > 0">
          <h3>Recent delivery failures</h3>
          <div class="failures">
            <div v-for="(f, i) in health.recent_failures" :key="i" class="failure">
              <div class="failure-head">
                <span class="failure-user">@{{ f.username }}</span>
                <span class="badge badge-danger">{{ f.attempts }} attempts</span>
              </div>
              <div class="failure-inbox mono">{{ f.inbox_url }}</div>
              <div class="failure-error">{{ f.last_error }}</div>
            </div>
          </div>
        </section>

        <!-- Users -->
        <section>
          <div class="users-header">
            <h3 style="margin: 0;">Users</h3>
            <div class="users-toolbar">
              <input
                v-model="usersSearch"
                type="search"
                placeholder="Search username…"
                @input="onSearchInput"
                class="users-search"
              />
              <span class="muted" style="font-size: 0.85rem;">
                {{ usersTotal }} user{{ usersTotal === 1 ? '' : 's' }}
              </span>
            </div>
          </div>

          <div class="table-wrap">
            <table class="table">
              <thead>
                <tr>
                  <th @click="usersSortBy('username')" class="sortable">
                    Username<span class="arrow">{{ sortArrow('username') }}</span>
                  </th>
                  <th>Status</th>
                  <th @click="usersSortBy('videos')" class="sortable num">
                    Videos<span class="arrow">{{ sortArrow('videos') }}</span>
                  </th>
                  <th @click="usersSortBy('followers')" class="sortable num">
                    Followers<span class="arrow">{{ sortArrow('followers') }}</span>
                  </th>
                  <th @click="usersSortBy('following')" class="sortable num">
                    Following<span class="arrow">{{ sortArrow('following') }}</span>
                  </th>
                  <th class="num">Comments</th>
                  <th @click="usersSortBy('created_at')" class="sortable">
                    Created<span class="arrow">{{ sortArrow('created_at') }}</span>
                  </th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="u in users" :key="u.username" :class="{ 'row-disabled': u.disabled }">
                  <td>
                    <RouterLink :to="`/users/${u.username}`" class="user-link">@{{ u.username }}</RouterLink>
                  </td>
                  <td>
                    <span v-if="u.disabled" class="badge badge-danger">disabled</span>
                    <span v-else class="badge badge-success">active</span>
                  </td>
                  <td class="num">{{ u.video_count }}</td>
                  <td class="num">{{ u.followers_count }}</td>
                  <td class="num">{{ u.following_count }}</td>
                  <td class="num">{{ u.comment_count }}</td>
                  <td class="muted">{{ fmtRel(u.created_at) }}</td>
                  <td class="actions">
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
                      :disabled="busyUser === u.username"
                      @click="deleteUser(u.username)"
                    >Delete</button>
                  </td>
                </tr>
                <tr v-if="users.length === 0 && !usersLoading">
                  <td colspan="8" class="muted" style="text-align: center; padding: 2rem;">
                    <template v-if="usersSearch">No users match "{{ usersSearch }}".</template>
                    <template v-else>No users yet.</template>
                  </td>
                </tr>
                <tr v-if="usersLoading">
                  <td colspan="8" class="muted" style="text-align: center; padding: 1rem;">
                    Loading…
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <div v-if="usersPageCount > 1" class="pager pager-bottom">
            <button class="btn btn-sm" :disabled="usersOffset === 0 || usersLoading" @click="usersPrev">← Prev</button>
            <span class="muted">Page {{ usersPage }} / {{ usersPageCount }}</span>
            <button class="btn btn-sm" :disabled="!usersHasMore || usersLoading" @click="usersNext">Next →</button>
          </div>
        </section>
      </template>

      <!-- TABLES -->
      <template v-if="tab === 'tables'">
        <div class="tables-layout">
          <aside class="tables-sidebar">
            <div
              v-for="t in tables"
              :key="t.name"
              class="table-item"
              :class="{ active: selectedTable === t.name }"
              @click="openTable(t.name)"
            >
              <span class="table-name mono">{{ t.name }}</span>
              <span class="table-count">{{ t.count }}</span>
            </div>
          </aside>

          <div class="tables-main">
            <div v-if="!selectedTable" class="empty">
              Select a table on the left to browse its rows.
            </div>

            <template v-else-if="tableData">
              <div class="table-header">
                <div>
                  <div class="table-header-name mono">{{ selectedTable }}</div>
                  <div class="muted" style="font-size: 0.85rem;">
                    {{ tableData.totalItems }} rows
                    <template v-if="tableData.totalItems > 0">
                      · showing {{ tableOffset + 1 }}–{{ Math.min(tableOffset + tableLimit, tableData.totalItems) }}
                    </template>
                  </div>
                </div>
                <div class="pager">
                  <button
                    class="btn btn-sm"
                    :disabled="tableOffset === 0 || loading"
                    @click="prevPage"
                  >← Prev</button>
                  <button
                    class="btn btn-sm"
                    :disabled="!tableData.has_more || loading"
                    @click="nextPage"
                  >Next →</button>
                </div>
              </div>

              <div class="table-wrap">
                <table class="table table-compact">
                  <thead>
                    <tr>
                      <th v-for="c in tableColumns" :key="c" class="mono">{{ c }}</th>
                    </tr>
                  </thead>
                  <tbody>
                    <template v-for="(row, i) in tableData.items" :key="i">
                      <tr class="row" :class="{ 'row-open': expandedRow === i }" @click="toggleRow(i)">
                        <td v-for="c in tableColumns" :key="c" class="mono cell">
                          <template v-if="c === 'id'">
                            <span class="id-badge">{{ row[c] }}</span>
                          </template>
                          <template v-else-if="isTimestampKey(c) && row[c]">
                            <span :title="row[c]">{{ fmtRel(row[c]) }}</span>
                          </template>
                          <template v-else-if="isJsonKey(c)">
                            <span class="muted">{…}</span>
                          </template>
                          <template v-else-if="row[c] === null || row[c] === undefined">
                            <span class="null">—</span>
                          </template>
                          <template v-else-if="String(row[c]).length > 60">
                            <span :title="String(row[c])">{{ String(row[c]).slice(0, 60) }}…</span>
                          </template>
                          <template v-else>
                            {{ row[c] }}
                          </template>
                        </td>
                      </tr>
                      <tr v-if="expandedRow === i" class="row-detail">
                        <td :colspan="tableColumns.length">
                          <div class="detail-fields">
                            <div v-for="c in tableColumns" :key="c" class="detail-field">
                              <div class="detail-key mono">{{ c }}</div>
                              <div class="detail-value mono">
                                <template v-if="isJsonKey(c) && row[c]">
                                  <pre>{{ JSON.stringify(row[c], null, 2) }}</pre>
                                </template>
                                <template v-else-if="row[c] === null || row[c] === undefined">
                                  <span class="null">null</span>
                                </template>
                                <template v-else>
                                  {{ row[c] }}
                                </template>
                              </div>
                            </div>
                          </div>
                        </td>
                      </tr>
                    </template>
                    <tr v-if="tableData.items.length === 0">
                      <td :colspan="tableColumns.length" class="muted" style="text-align: center; padding: 2rem;">
                        No rows.
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>

              <div v-if="tableData.totalItems > tableLimit" class="pager pager-bottom">
                <button
                  class="btn btn-sm"
                  :disabled="tableOffset === 0 || loading"
                  @click="prevPage"
                >← Prev</button>
                <span class="muted">
                  Page {{ Math.floor(tableOffset / tableLimit) + 1 }}
                  of {{ Math.ceil(tableData.totalItems / tableLimit) }}
                </span>
                <button
                  class="btn btn-sm"
                  :disabled="!tableData.has_more || loading"
                  @click="nextPage"
                >Next →</button>
              </div>
            </template>
          </div>
        </div>
      </template>
    </template>
  </div>
</template>

<style scoped>
.admin-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 1rem;
    flex-wrap: wrap;
}

.tabs {
    display: flex;
    gap: 0.25rem;
    border-bottom: 1px solid #232833;
    margin-bottom: 1rem;
}
html:not(.dark) .tabs { border-color: #e7e7ec; }

.tab {
    padding: 0.6rem 1rem;
    background: transparent;
    border: 0;
    border-bottom: 2px solid transparent;
    color: #6a7180;
    font-family: inherit;
    font-size: 0.9rem;
    font-weight: 600;
    cursor: pointer;
    transition: color 0.15s, border-color 0.15s;
}
.tab:hover { color: #f4f4f7; }
.tab.active { color: #f4f4f7; border-bottom-color: #8b5cf6; }
html:not(.dark) .tab.active { color: #0e0f14; }

/* --- Workers --- */
.worker-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
    gap: 0.75rem;
}
.worker-card {
    padding: 1.1rem 1.25rem;
    background: #14171f;
    border: 1px solid #232833;
    border-radius: 14px;
}
html:not(.dark) .worker-card { background: #fff; border-color: #e7e7ec; }
.worker-card-head {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 0.5rem;
    margin-bottom: 0.9rem;
}
.worker-card-title { font-weight: 700; font-size: 0.95rem; }
.worker-card-msg { color: #6a7180; font-size: 0.8rem; margin-top: 0.15rem; }
.worker-card-stats { display: flex; gap: 1.5rem; }
.worker-stat-label {
    font-size: 0.7rem;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: #6a7180;
    font-weight: 600;
}
.worker-stat-value { font-weight: 700; font-size: 0.95rem; }

/* --- Stat tiles --- */
.stat-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
    gap: 0.6rem;
}
.stat-tile {
    padding: 0.9rem 1rem;
    background: #14171f;
    border: 1px solid #232833;
    border-radius: 12px;
}
html:not(.dark) .stat-tile { background: #fff; border-color: #e7e7ec; }
.stat-tile-value {
    font-size: 1.5rem;
    font-weight: 800;
    letter-spacing: -0.02em;
    line-height: 1;
    margin-bottom: 0.25rem;
}
.stat-tile-value.bad { color: #ef4444; }
.stat-tile-label {
    font-size: 0.72rem;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: #6a7180;
    font-weight: 600;
}

/* --- Failures --- */
.failures { display: flex; flex-direction: column; gap: 0.5rem; }
.failure {
    padding: 0.7rem 0.9rem;
    background: rgba(239, 68, 68, 0.06);
    border: 1px solid rgba(239, 68, 68, 0.2);
    border-radius: 10px;
}
.failure-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 0.5rem;
    margin-bottom: 0.35rem;
}
.failure-user { font-weight: 700; }
.failure-inbox { color: #6a7180; font-size: 0.78rem; word-break: break-all; }
.failure-error { color: #ef4444; font-size: 0.85rem; margin-top: 0.25rem; }

/* --- Tables --- */
.tables-layout {
    display: grid;
    grid-template-columns: 220px 1fr;
    gap: 1rem;
    align-items: start;
}

.tables-sidebar {
    display: flex;
    flex-direction: column;
    gap: 0.15rem;
    max-height: 70vh;
    overflow-y: auto;
    background: #14171f;
    border: 1px solid #232833;
    border-radius: 14px;
    padding: 0.4rem;
}
html:not(.dark) .tables-sidebar { background: #fff; border-color: #e7e7ec; }

.table-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 0.5rem;
    padding: 0.5rem 0.75rem;
    border-radius: 8px;
    cursor: pointer;
    font-size: 0.85rem;
    transition: background 0.15s;
}
.table-item:hover { background: #252a35; }
.table-item.active { background: #8b5cf6; color: #fff; }
html:not(.dark) .table-item:hover { background: #f3f3f6; }
html:not(.dark) .table-item.active { background: #7c3aed; color: #fff; }

.table-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.table-count {
    font-size: 0.72rem;
    color: #6a7180;
    flex-shrink: 0;
    font-weight: 600;
}
.table-item.active .table-count { color: rgba(255, 255, 255, 0.75); }

.tables-main { min-width: 0; }
.table-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 1rem;
    flex-wrap: wrap;
    margin-bottom: 0.75rem;
}
.table-header-name { font-weight: 700; font-size: 1rem; }

.table-wrap {
    overflow-x: auto;
    background: #14171f;
    border: 1px solid #232833;
    border-radius: 12px;
}
html:not(.dark) .table-wrap { background: #fff; border-color: #e7e7ec; }

.table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
.table th {
    text-align: left;
    padding: 0.6rem 0.75rem;
    font-size: 0.72rem;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: #6a7180;
    font-weight: 600;
    border-bottom: 1px solid #232833;
    white-space: nowrap;
    background: #191c26;
}
html:not(.dark) .table th { background: #f8f8fa; border-color: #e7e7ec; }

.table td {
    padding: 0.55rem 0.75rem;
    border-bottom: 1px solid #232833;
}
html:not(.dark) .table td { border-color: #e7e7ec; }
.table tbody tr:last-child td { border-bottom: 0; }
.table .num { text-align: right; }

.table-compact th,
.table-compact td {
    padding: 0.45rem 0.7rem;
    font-size: 0.8rem;
}
.table-compact .cell {
    max-width: 260px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.row { cursor: pointer; transition: background 0.1s; }
.row:hover { background: #1c2029; }
html:not(.dark) .row:hover { background: #f3f3f6; }
.row-open { background: #1c2029; }
html:not(.dark) .row-open { background: #f3f3f6; }

.id-badge {
    display: inline-block;
    padding: 0.1rem 0.45rem;
    background: #252a35;
    color: #a1a7b3;
    border-radius: 5px;
    font-size: 0.75rem;
    font-weight: 600;
}
html:not(.dark) .id-badge { background: #e7e7ec; color: #5a5f6d; }

.null { color: #5c5c66; font-style: italic; }

.row-detail td { padding: 0; border: 0; }
.detail-fields {
    display: grid;
    grid-template-columns: 180px 1fr;
    gap: 0.4rem 1rem;
    padding: 1rem 1.25rem;
    background: #191c26;
    border-top: 1px solid #232833;
    border-bottom: 1px solid #232833;
}
html:not(.dark) .detail-fields { background: #f8f8fa; border-color: #e7e7ec; }

.detail-key {
    font-size: 0.75rem;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: #6a7180;
    font-weight: 600;
    padding-top: 0.15rem;
}
.detail-value {
    color: #f4f4f7;
    font-size: 0.85rem;
    word-break: break-word;
    white-space: pre-wrap;
}
html:not(.dark) .detail-value { color: #0e0f14; }
.detail-value pre {
    margin: 0;
    padding: 0.5rem 0.75rem;
    background: #14171f;
    border: 1px solid #232833;
    border-radius: 8px;
    font-size: 0.78rem;
    max-height: 300px;
    overflow: auto;
    white-space: pre-wrap;
    word-break: break-all;
}
html:not(.dark) .detail-value pre { background: #fff; border-color: #e7e7ec; }

.user-link {
    color: #8b5cf6;
    font-weight: 600;
    text-decoration: none;
}
.user-link:hover { text-decoration: underline; }

@media (max-width: 700px) {
    .tables-layout { grid-template-columns: 1fr; }
    .tables-sidebar { max-height: 240px; }
    .detail-fields { grid-template-columns: 1fr; gap: 0.75rem; }
}

.row-disabled td { opacity: 0.55; }

.pager {
    display: flex;
    align-items: center;
    gap: 0.5rem;
}

.pager-bottom {
    justify-content: center;
    margin-top: 1rem;
    padding-top: 1rem;
    border-top: 1px solid #232833;
}
html:not(.dark) .pager-bottom { border-color: #e7e7ec; }

.table-wrap {
    overflow-x: auto;
    background: #14171f;
    border: 1px solid #232833;
    border-radius: 12px;
}
html:not(.dark) .table-wrap { background: #fff; border-color: #e7e7ec; }

.table-compact th {
    position: sticky;
    top: 0;
    z-index: 1;
    background: #191c26;
}
html:not(.dark) .table-compact th { background: #f8f8fa; }

.table-compact .cell {
    max-width: 200px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.row {
    cursor: pointer;
    transition: background 0.1s;
}
.row:hover { background: #1c2029; }
html:not(.dark) .row:hover { background: #f3f3f6; }
.row-open { background: #1c2029; }
html:not(.dark) .row-open { background: #f3f3f6; }

.id-badge {
    display: inline-block;
    padding: 0.1rem 0.45rem;
    background: #252a35;
    color: #a1a7b3;
    border-radius: 5px;
    font-size: 0.75rem;
    font-weight: 600;
}
html:not(.dark) .id-badge { background: #e7e7ec; color: #5a5f6d; }

.null { color: #5c5c66; font-style: italic; }

.row-detail td {
    padding: 0;
    border: 0;
}
.detail-fields {
    display: grid;
    grid-template-columns: 180px 1fr;
    gap: 0.4rem 1rem;
    padding: 1rem 1.25rem;
    background: #191c26;
    border-top: 1px solid #232833;
    border-bottom: 1px solid #232833;
}
html:not(.dark) .detail-fields { background: #f8f8fa; border-color: #e7e7ec; }

.detail-key {
    font-size: 0.75rem;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: #6a7180;
    font-weight: 600;
    padding-top: 0.15rem;
}
.detail-value {
    color: #f4f4f7;
    font-size: 0.85rem;
    word-break: break-word;
    white-space: pre-wrap;
}
html:not(.dark) .detail-value { color: #0e0f14; }

.detail-value pre {
    margin: 0;
    padding: 0.5rem 0.75rem;
    background: #14171f;
    border: 1px solid #232833;
    border-radius: 8px;
    font-size: 0.78rem;
    max-height: 300px;
    overflow: auto;
    white-space: pre-wrap;
    word-break: break-all;
}
html:not(.dark) .detail-value pre { background: #fff; border-color: #e7e7ec; }

.users-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 1rem;
    flex-wrap: wrap;
    margin-bottom: 0.75rem;
}

.users-toolbar {
    display: flex;
    align-items: center;
    gap: 1rem;
}

.users-search {
    width: 240px;
    padding: 0.4rem 0.75rem;
    font-size: 0.88rem;
}

.sortable {
    cursor: pointer;
    user-select: none;
    transition: color 0.15s;
}
.sortable:hover { color: #f4f4f7; }
html:not(.dark) .sortable:hover { color: #0e0f14; }

.arrow {
    color: #8b5cf6;
    font-weight: 700;
}

.actions {
    display: flex;
    gap: 0.4rem;
    white-space: nowrap;
}

.row-disabled td { opacity: 0.55; }
</style>
