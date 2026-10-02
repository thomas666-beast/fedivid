<script setup>
import { ref, onMounted, onBeforeUnmount, watch, computed, nextTick } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { getSession, listThread, sendMessage, markThreadRead, deleteThread } from '../api'
import { onMessage } from '../lib/messageBus'
import { fmtChatTime } from '../utils/format'
import Icon from '../components/Icon.vue'
import Avatar from '../components/Avatar.vue'

const route = useRoute()
const router = useRouter()

const items = ref([])
const me = ref(null)
const draft = ref('')
const busy = ref(false)
const error = ref(null)
const threadEl = ref(null)
const page = ref(1)
const perPage = 30
let unsubscribe = null
let readTimer = null

// route.params.username is decoded by Vue Router — "alice@localhost:3000"
const other = computed(() => {
  let u = String(route.params.username || '').replace(/^@/, '')
  return u
})

const otherDisplay = computed(() => other.value)

const otherShort = computed(() => {
  const at = other.value.indexOf('@')
  return at >= 0 ? other.value.slice(0, at) : other.value
})

const pageCount = computed(() => Math.max(1, Math.ceil(items.value.length / perPage)))
const pagedItems = computed(() => {
  const end = items.value.length - (page.value - 1) * perPage
  const start = Math.max(0, end - perPage)
  return items.value.slice(start, end)
})

async function scrollToBottom() {
  await nextTick()
  if (threadEl.value) threadEl.value.scrollTop = threadEl.value.scrollHeight
}

async function load() {
  error.value = null
  try {
    const sess = await getSession()
    if (!sess) { router.push('/login'); return }
    me.value = sess

    const data = await listThread(other.value)
    items.value = data.items || []
    page.value = 1
    await scrollToBottom()

    // Best effort — the read marker doesn't block the UI
    try { await markThreadRead(other.value) } catch { /* ignore */ }
  } catch (e) {
    error.value = e.message
  }
}

function onSocketMessage(msg) {
  const senderShort = (msg.sender || '')
    .replace(/^@/, '')
    .split('@')[0]
    .replace(/^.*\//, '')

  if (senderShort !== otherShort.value) return

  items.value.push({
    id: msg.id,
    sender: msg.sender,
    body: msg.body,
    created_at: msg.created_at,
  })
  page.value = 1
  scrollToBottom()

  // Debounce: mark read at most once per second as messages stream in.
  clearTimeout(readTimer)
  readTimer = setTimeout(() => {
    markThreadRead(other.value).catch(() => { /* ignore */ })
  }, 1000)
}

async function submit() {
  const text = draft.value.trim()
  if (!text) return
  busy.value = true
  error.value = null
  try {
    const created = await sendMessage(me.value.username, other.value, text)
    items.value.push({
      id: created.id,
      sender: created.sender,
      body: created.body,
      created_at: created.created_at,
    })
    draft.value = ''
    page.value = 1
    await scrollToBottom()
  } catch (e) {
    error.value = e.message
  } finally {
    busy.value = false
  }
}

function isMine(m) {
  if (!me.value) return false
  if (m.sender === me.value.username) return true
  if (m.sender && m.sender.endsWith(`/users/${me.value.username}`)) return true
  return false
}

async function deleteConversation() {
  if (!confirm(`Delete this conversation with @${otherShort.value}? This only removes it from your view.`)) return
  try {
    await deleteThread(other.value)
    router.push('/messages')
  } catch (e) {
    alert(e.message)
  }
}

onMounted(async () => {
  await load()
  unsubscribe = onMessage(onSocketMessage)
})

onBeforeUnmount(() => {
  if (unsubscribe) unsubscribe()
  if (readTimer) clearTimeout(readTimer)
})

watch(() => route.params.username, load)
</script>

<template>
  <div class="thread-page">
    <div class="thread-header">
      <RouterLink to="/messages" class="back-link">
        <Icon name="menu" :size="18" />
      </RouterLink>
      <Avatar :username="otherShort" size="md" />
      <div style="flex: 1; min-width: 0;">
        <div class="peer-name">@{{ otherDisplay }}</div>
        <div class="peer-status">Direct message</div>
      </div>
      <button class="btn btn-ghost btn-danger btn-sm" @click="deleteConversation">
        Delete
      </button>
    </div>

    <div ref="threadEl" class="thread-scroll">
      <div v-if="pageCount > 1" class="pager">
        <button class="btn btn-sm" :disabled="page === 1" @click="page--">← Older</button>
        <span class="muted">Page {{ page }} / {{ pageCount }}</span>
        <button class="btn btn-sm" :disabled="page === pageCount" @click="page++">Newer →</button>
      </div>

      <div v-if="items.length === 0" class="empty-thread">
        No messages yet. Say hello.
      </div>

      <div
        v-for="m in pagedItems"
        :key="m.id"
        class="msg-row"
        :class="isMine(m) ? 'msg-mine' : 'msg-theirs'"
      >
        <div class="msg-bubble">
          <p class="msg-body">{{ m.body }}</p>
          <p class="msg-time">{{ fmtChatTime(m.created_at) }}</p>
        </div>
      </div>
    </div>

    <form v-if="me" @submit.prevent="submit" class="composer">
      <textarea
        v-model="draft"
        rows="1"
        maxlength="5000"
        placeholder="Write a message…"
        @keydown.enter.exact.prevent="submit"
      ></textarea>
      <button type="submit" class="send-btn" :disabled="busy || !draft.trim()">
        <Icon name="send" :size="18" />
      </button>
    </form>

    <p v-if="error" class="error">{{ error }}</p>
  </div>
</template>

<style scoped>
.thread-page {
    display: flex;
    flex-direction: column;
    height: calc(100vh - 8rem);
    max-height: 780px;
    border: 1px solid #232833;
    border-radius: 20px;
    overflow: hidden;
    background: #14171f;
}
html:not(.dark) .thread-page { background: #fff; border-color: #e7e7ec; }

.thread-header {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    padding: 0.75rem 1rem;
    border-bottom: 1px solid #232833;
}
html:not(.dark) .thread-header { border-color: #e7e7ec; }

.back-link {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 32px;
    height: 32px;
    color: #a1a7b3;
    text-decoration: none;
    border-radius: 8px;
    transform: rotate(180deg);
}
.back-link:hover { background: #252a35; color: #f4f4f7; }

.peer-name { font-weight: 700; font-size: 0.95rem; }
.peer-status { font-size: 0.75rem; color: #6a7180; }

.thread-scroll {
    flex: 1;
    overflow-y: auto;
    padding: 1rem;
    display: flex;
    flex-direction: column;
    gap: 0.4rem;
}

.pager {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 1rem;
    padding-bottom: 0.5rem;
    margin-bottom: 0.5rem;
    border-bottom: 1px solid #232833;
}
html:not(.dark) .pager { border-color: #e7e7ec; }

.empty-thread {
    color: #6a7180;
    text-align: center;
    margin: auto;
    font-size: 0.9rem;
}

.msg-row { display: flex; align-items: flex-end; }
.msg-mine { justify-content: flex-end; }
.msg-theirs { justify-content: flex-start; }

.msg-bubble {
    max-width: 72%;
    padding: 0.55rem 0.9rem;
    border-radius: 18px;
    line-height: 1.4;
    word-wrap: break-word;
}
.msg-mine .msg-bubble {
    background: #8b5cf6;
    color: #fff;
    border-bottom-right-radius: 6px;
}
.msg-theirs .msg-bubble {
    background: #1c2029;
    color: #f4f4f7;
    border-bottom-left-radius: 6px;
}
html:not(.dark) .msg-theirs .msg-bubble {
    background: #f3f3f6;
    color: #0e0f14;
}

.msg-body { margin: 0; font-size: 0.95rem; }
.msg-time {
    margin: 0.15rem 0 0;
    font-size: 0.68rem;
    opacity: 0.65;
    text-align: right;
}

.composer {
    display: flex;
    gap: 0.5rem;
    align-items: flex-end;
    padding: 0.75rem 1rem;
    border-top: 1px solid #232833;
}
html:not(.dark) .composer { border-color: #e7e7ec; }

.composer textarea {
    flex: 1;
    min-height: 2.5rem;
    max-height: 8rem;
    padding: 0.55rem 0.9rem;
    border-radius: 20px;
    resize: none;
}

.send-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 40px;
    height: 40px;
    flex-shrink: 0;
    background: #8b5cf6;
    color: #fff;
    border: 0;
    border-radius: 50%;
    cursor: pointer;
    transition: background 0.15s;
}
.send-btn:hover:not(:disabled) { background: #a78bfa; }
.send-btn:disabled { opacity: 0.5; cursor: not-allowed; }

.error { padding: 0 1rem 0.75rem; margin: 0; }
</style>
