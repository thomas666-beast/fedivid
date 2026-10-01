<script setup>
import { ref, onMounted } from 'vue'
import { useRouter, RouterLink } from 'vue-router'
import { getSession, getNotifications, markNotificationsSeen } from '../api'
import { fmtTime } from '../utils/format'
import Icon from '../components/Icon.vue'

const router = useRouter()
const emit = defineEmits(['marked-seen'])

const items = ref([])
const loading = ref(true)
const error = ref(null)

async function load() {
  loading.value = true
  error.value = null
  try {
    const sess = await getSession()
    if (!sess) { router.push('/login'); return }
    const data = await getNotifications(sess.username)
    items.value = data.items || []
    await markNotificationsSeen(sess.username)
    emit('marked-seen')
  } catch (e) {
    error.value = e.message
  } finally {
    loading.value = false
  }
}

function actorName(actor) {
  if (!actor) return 'someone'
  const m = actor.match(/^https?:\/\/[^/]+\/users\/([^\/]+)$/)
  if (m) return m[1]
  return actor.replace(/^https?:\/\//, '')
}

function actorHandle(actor) {
  if (!actor) return ''
  const m = actor.match(/^https?:\/\/[^/]+\/users\/([^\/]+)$/)
  if (m) return m[1]
  return '@' + actor.replace(/^https?:\/\//, '')
}

function actorLink(actor) {
  if (!actor) return '/'
  const m = actor.match(/^https?:\/\/[^/]+\/users\/([^\/]+)$/)
  if (m) {
    // Local actor (same host) → /users/:name
    // Remote → /remote/:handle
    const host = actor.replace(/^https?:\/\//, '').split('/')[0]
    if (host.startsWith(window.location.host)) {
      return `/users/${m[1]}`
    }
    return `/remote/${m[1]}@${host}`
  }
  return actor
}

// The main action link for the notification row
function targetLink(n) {
  switch (n.type) {
    case 'follow':
      return { type: 'link', to: actorLink(n.actor) }
    case 'create':
      if (n.video_id) return { type: 'link', to: `/v/${n.video_id}` }
      return { type: 'link', to: actorLink(n.actor) }
    case 'message':
      return { type: 'link', to: `/messages/thread/${actorName(n.actor)}` }
    case 'like':
    case 'comment':
    case 'announce':
      if (n.video_id) return { type: 'link', to: `/v/${n.video_id}` }
      if (n.object_url) return { type: 'external', href: n.object_url }
      return { type: 'link', to: actorLink(n.actor) }
    default:
      return { type: 'link', to: actorLink(n.actor) }
  }
}

function iconFor(type) {
  return {
    follow:   'users',
    like:     'heart',
    comment:  'comment',
    create:   'play',
    announce: 'repeat',
    message:  'message',
  }[type] || 'bell'
}

function verbFor(type) {
  return {
    follow:   'started following you',
    like:     'liked your video',
    comment:  'commented on your video',
    create:   'posted a new video',
    announce: 'boosted a video',
    message:  'sent you a message',
  }[type] || 'did something'
}

onMounted(load)
</script>

<template>
  <div class="stack">
    <div>
      <h1>Notifications</h1>
      <p class="muted">Recent activity on your account.</p>
    </div>

    <p v-if="loading" class="loading">Loading…</p>
    <p v-else-if="error" class="error">{{ error }}</p>

    <div v-else-if="items.length === 0" class="empty">
      <Icon name="bell" :size="32" style="margin: 0 auto 0.75rem; display: block; color: #6a7180;" />
      <p style="margin: 0;">No notifications yet.</p>
      <p class="muted" style="margin: 0.25rem 0 0;">When people follow, like, or comment, it shows up here.</p>
    </div>

    <div v-else class="notif-list">
      <component
        v-for="n in items"
        :key="n.id"
        :is="targetLink(n).type === 'external' ? 'a' : 'RouterLink'"
        :href="targetLink(n).type === 'external' ? targetLink(n).href : null"
        :to="targetLink(n).type === 'link' ? targetLink(n).to : null"
        :target="targetLink(n).type === 'external' ? '_blank' : null"
        :rel="targetLink(n).type === 'external' ? 'noopener' : null"
        class="notif"
      >
        <div class="notif-icon" :class="`notif-icon-${n.type}`">
          <Icon :name="iconFor(n.type)" :size="16" />
        </div>

        <div class="notif-body">
          <p class="notif-text">
            <span class="notif-actor">@{{ actorHandle(n.actor).replace(/^@/, '') }}</span>
            <span class="notif-verb">{{ verbFor(n.type) }}</span>
          </p>
        </div>

        <span class="notif-time">{{ fmtTime(n.created_at) }}</span>
      </component>
    </div>
  </div>
</template>

<style scoped>
.notif-list { display: flex; flex-direction: column; gap: 0.5rem; }

.notif {
    display: flex;
    align-items: center;
    gap: 1rem;
    padding: 0.9rem 1.1rem;
    background: #14171f;
    border: 1px solid #232833;
    border-radius: 14px;
    transition: border-color 0.15s, background 0.15s;
    color: inherit;
    text-decoration: none;
    cursor: pointer;
}
.notif:hover { border-color: #333a48; background: #181c26; }
html:not(.dark) .notif { background: #fff; border-color: #e7e7ec; }
html:not(.dark) .notif:hover { background: #f3f3f6; }

.notif-icon {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 36px;
    height: 36px;
    border-radius: 10px;
    flex-shrink: 0;
    background: #1c2029;
    color: #a1a7b3;
}
.notif-icon-follow   { background: rgba(139, 92, 246, 0.15); color: #8b5cf6; }
.notif-icon-like     { background: rgba(236, 72, 153, 0.15); color: #ec4899; }
.notif-icon-comment  { background: rgba(34, 197, 94, 0.15); color: #22c55e; }
.notif-icon-create   { background: rgba(59, 130, 246, 0.15); color: #3b82f6; }
.notif-icon-announce { background: rgba(16, 185, 129, 0.15); color: #10b981; }
.notif-icon-message  { background: rgba(245, 158, 11, 0.15); color: #f59e0b; }

.notif-body { flex: 1; min-width: 0; }

.notif-text {
    margin: 0;
    font-size: 0.95rem;
    color: #f4f4f7;
    line-height: 1.4;
}
html:not(.dark) .notif-text { color: #0e0f14; }

.notif-actor {
    font-weight: 700;
    color: #8b5cf6;
}

.notif-verb {
    color: #a1a7b3;
    margin-left: 0.3rem;
}

.notif-time {
    font-size: 0.78rem;
    color: #6a7180;
    white-space: nowrap;
    flex-shrink: 0;
}
</style>
