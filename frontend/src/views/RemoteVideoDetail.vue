<script setup>
import { ref, onMounted, watch, computed } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { getSession, getRemoteVideo, boost, unboost } from '../api'
import { fmtCount, fmtTime } from '../utils/format'
import Comments from '../components/Comments.vue'
import Icon from '../components/Icon.vue'

const route = useRoute()
const router = useRouter()

const video = ref(null)
const loading = ref(true)
const error = ref(null)
const me = ref(null)
const boosted = ref(false)
const boostBusy = ref(false)

// Convert remote_actor URL to display handle and link
// "http://localhost:3000/users/alice" → { display: "alice@localhost:3000", link: "/remote/alice@localhost:3000" }
const authorInfo = computed(() => {
  if (!video.value) return { display: '', link: '/' }

  const actor = video.value.remote_actor || ''
  const clean = actor.replace(/^https?:\/\//, '')
  const parts = clean.split('/users/')

  if (parts.length === 2) {
    const [host, user] = parts
    return {
      display: `${user}@${host}`,
      link: `/remote/${user}@${host}`,
    }
  }

  return { display: clean, link: actor }
})

async function load() {
  loading.value = true
  error.value = null
  try {
    const [v, sess] = await Promise.all([
      getRemoteVideo(route.params.id),
      getSession(),
    ])
    if (!v) throw new Error('Video not found')
    video.value = v
    me.value = sess

    if (sess) {
      try {
        const list = await fetch(
          `/api/users/${encodeURIComponent(sess.username)}/announces`,
          { credentials: 'include' }
        ).then(r => r.json())
        boosted.value = (list.items || []).some(a => a.object === v.object_id)
      } catch { /* ignore */ }
    }
  } catch (e) {
    error.value = e.message
  } finally {
    loading.value = false
  }
}

async function toggleBoost() {
  if (!me.value || !video.value || boostBusy.value) return
  boostBusy.value = true

  if (boosted.value) {
    boosted.value = false
    video.value.boost_count = Math.max(0, video.value.boost_count - 1)
    try { await unboost(me.value.username, video.value.object_id) } catch {
      boosted.value = true
      video.value.boost_count += 1
    }
  } else {
    boosted.value = true
    video.value.boost_count += 1
    try { await boost(me.value.username, video.value.object_id) } catch {
      boosted.value = false
      video.value.boost_count = Math.max(0, video.value.boost_count - 1)
    }
  }

  boostBusy.value = false
}

async function share() {
  try { await navigator.clipboard.writeText(window.location.href) } catch { /* ignore */ }
}

onMounted(load)
watch(() => route.params.id, load)
</script>

<template>
  <div class="stack">
    <button class="btn btn-ghost btn-sm" @click="router.back()">← Back</button>

    <p v-if="loading" class="loading">Loading…</p>
    <p v-else-if="error" class="error">{{ error }}</p>

    <template v-else-if="video">
      <div style="border-radius: 20px; overflow: hidden; background: #000;">
        <video
          v-if="video.url"
          controls
          preload="metadata"
          :src="video.url"
          class="player"
        />
        <div v-else class="empty">No playable URL for this remote video.</div>
      </div>

      <div>
        <h1 style="margin: 0 0 0.75rem; font-size: 1.5rem; font-weight: 800; letter-spacing: -0.02em;">
          {{ video.title || '(untitled)' }}
        </h1>

        <div class="remote-author">
          <RouterLink :to="authorInfo.link" class="remote-avatar">
            {{ authorInfo.display[0]?.toUpperCase() || '?' }}
          </RouterLink>

          <div>
            <RouterLink :to="authorInfo.link" class="remote-name">
              @{{ authorInfo.display }}
            </RouterLink>
            <p class="muted" style="margin: 0; font-size: 0.8rem;">
              Remote · {{ fmtTime(video.published_at) }}
            </p>
          </div>

          <div style="margin-left: auto; display: flex; gap: 0.5rem; flex-wrap: wrap;">
            <button
              class="btn btn-sm"
              :class="{ 'btn-primary': boosted }"
              :disabled="!me || boostBusy"
              @click="toggleBoost"
            >
              <Icon name="repeat" :size="14" />
              <span v-if="video.boost_count > 0">
                {{ fmtCount(video.boost_count) }}
              </span>
              <span v-else>Boost</span>
            </button>

            <button class="btn btn-sm" @click="share">
              <Icon name="send" :size="14" /> Share
            </button>

            <a :href="video.remote_actor" target="_blank" rel="noopener" class="btn btn-sm">
              View on remote
            </a>
          </div>
        </div>

        <p v-if="video.description" class="remote-description">{{ video.description }}</p>

        <div class="remote-meta">
          <span v-if="video.duration">{{ Math.round(video.duration) }}s</span>
          <span v-if="video.width && video.height">{{ video.width }} × {{ video.height }}</span>
          <span v-if="video.comment_count > 0">
            {{ fmtCount(video.comment_count) }} {{ video.comment_count === 1 ? 'comment' : 'comments' }}
          </span>
        </div>
      </div>

      <div class="card">
        <Comments :username="video.username" :video-id="video.id" source="remote" />
      </div>
    </template>
  </div>
</template>

<style scoped>
.player {
    width: 100%;
    aspect-ratio: 16 / 9;
    background: #000;
    display: block;
}

.remote-author {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    padding: 1rem 0;
    border-top: 1px solid #232833;
    border-bottom: 1px solid #232833;
    flex-wrap: wrap;
}
html:not(.dark) .remote-author { border-color: #e7e7ec; }

.remote-avatar {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 40px;
    height: 40px;
    background: linear-gradient(135deg, #6366f1, #8b5cf6);
    color: white;
    border-radius: 9999px;
    font-weight: 700;
    font-size: 1rem;
    flex-shrink: 0;
    text-decoration: none;
}

.remote-name {
    color: #f4f4f7;
    font-weight: 700;
    font-size: 0.95rem;
    text-decoration: none;
    word-break: break-all;
}
.remote-name:hover { color: #8b5cf6; }
html:not(.dark) .remote-name { color: #0e0f14; }

.remote-description {
    margin: 1rem 0;
    color: #a1a7b3;
    font-size: 0.95rem;
    line-height: 1.6;
    white-space: pre-wrap;
}

.remote-meta {
    display: flex;
    gap: 1rem;
    align-items: center;
    flex-wrap: wrap;
    font-size: 0.85rem;
    color: #6a7180;
}
</style>
