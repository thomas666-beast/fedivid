<script setup>
import { ref, onMounted, onBeforeUnmount, watch, computed } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { getSession, likeVideo, unlikeVideo, likeStatus, boost, unboost, updateVideo, deleteVideo, getMyBoosts } from '../api'
import { fmtCount, fmtTime } from '../utils/format'
import VideoPlayer from '../components/VideoPlayer.vue'
import Comments from '../components/Comments.vue'
import Avatar from '../components/Avatar.vue'
import Icon from '../components/Icon.vue'

const route = useRoute()
const router = useRouter()

const video = ref(null)
const loading = ref(true)
const error = ref(null)
const me = ref(null)
const liked = ref(false)
const boosted = ref(false)
const boostBusy = ref(false)
const menuOpen = ref(false)
const ownerMenuWrap = ref(null)
const editing = ref(false)
const editTitle = ref('')
const editDescription = ref('')
const editBusy = ref(false)
const editError = ref(null)

const isOwner = computed(() => me.value && video.value && me.value.username === video.value.username)

async function load() {
  loading.value = true
  error.value = null
  try {
    const [res, sess] = await Promise.all([
      fetch(`/api/users/${encodeURIComponent(route.params.username)}/videos/${encodeURIComponent(route.params.id)}`),
      getSession(),
    ])
    if (!res.ok) throw new Error(res.status === 404 ? 'Video not found' : `HTTP ${res.status}`)
    video.value = await res.json()
    me.value = sess

    if (sess && video.value.source === 'local') {
      try {
        const status = await likeStatus(sess.username, video.value.id)
        liked.value = !!status.liked
      } catch { /* ignore */ }

      try {
        const boosts = await getMyBoosts(sess.username)
        boosted.value = boosts.has(video.value.url)
      } catch { /* ignore */ }
    }
  } catch (e) {
    error.value = e.message
  } finally {
    loading.value = false
  }
}

async function toggleLike() {
  if (!me.value || !video.value) return
  if (liked.value) {
    liked.value = false
    video.value.like_count = Math.max(0, (video.value.like_count || 0) - 1)
    try { await unlikeVideo(me.value.username, video.value.id) } catch { /* ignore */ }
  } else {
    liked.value = true
    video.value.like_count = (video.value.like_count || 0) + 1
    try { await likeVideo(me.value.username, video.value.id) } catch { /* ignore */ }
  }
}

async function toggleBoost() {
  if (!me.value || !video.value || boostBusy.value) return
  boostBusy.value = true

  if (boosted.value) {
    boosted.value = false
    video.value.boost_count = Math.max(0, (video.value.boost_count || 0) - 1)
    try { await unboost(me.value.username, video.value.url) } catch {
      boosted.value = true
      video.value.boost_count = (video.value.boost_count || 0) + 1
    }
  } else {
    boosted.value = true
    video.value.boost_count = (video.value.boost_count || 0) + 1
    try { await boost(me.value.username, video.value.url) } catch {
      boosted.value = false
      video.value.boost_count = Math.max(0, (video.value.boost_count || 0) - 1)
    }
  }

  boostBusy.value = false
}

async function share() {
  try { await navigator.clipboard.writeText(window.location.href) } catch { /* ignore */ }
}

function startEdit() {
  menuOpen.value = false
  editTitle.value = video.value.title
  editDescription.value = video.value.description || ''
  editing.value = true
  editError.value = null
}

async function saveEdit() {
  editError.value = null
  editBusy.value = true
  try {
    await updateVideo(video.value.username, video.value.id, {
      title: editTitle.value.trim(),
      description: editDescription.value.trim(),
    })
    video.value.title = editTitle.value.trim()
    video.value.description = editDescription.value.trim()
    editing.value = false
  } catch (e) {
    editError.value = e.message
  } finally {
    editBusy.value = false
  }
}

async function doDelete() {
  menuOpen.value = false
  if (!confirm('Delete this video? This cannot be undone.')) return
  try {
    await deleteVideo(video.value.username, video.value.id)
    router.push(`/users/${video.value.username}`)
  } catch (e) {
    error.value = e.message
  }
}

function handleDocumentClick(e) {
  if (!menuOpen.value) return
  const el = ownerMenuWrap.value
  if (el && !el.contains(e.target)) {
    menuOpen.value = false
  }
}

onMounted(() => {
  load()
  document.addEventListener('click', handleDocumentClick)
})

onBeforeUnmount(() => {
  document.removeEventListener('click', handleDocumentClick)
})

watch(() => [route.params.username, route.params.id], load)
</script>

<template>
  <div class="stack">
    <button class="btn btn-ghost btn-sm" @click="router.back()">← Back</button>

    <p v-if="loading" class="loading">Loading…</p>
    <p v-else-if="error" class="error">{{ error }}</p>

    <template v-else-if="video">
      <div style="border-radius: 20px; overflow: hidden;">
        <VideoPlayer
          v-if="video.hls_url || video.url"
          :hls-src="video.hls_url"
          :fallback="video.url"
        />
        <div v-else class="empty" style="border-radius: 20px;">Video is still processing.</div>
      </div>

      <div>
        <div style="display: flex; align-items: flex-start; justify-content: space-between; gap: 1rem;">
          <h1 style="margin: 0 0 0.75rem; font-size: 1.5rem; font-weight: 800; letter-spacing: -0.02em; flex: 1;">
            {{ video.title || '(untitled)' }}
          </h1>

          <div v-if="isOwner" ref="ownerMenuWrap" style="position: relative;">
            <button class="btn btn-ghost btn-sm" @click.stop="menuOpen = !menuOpen">
              <Icon name="settings" :size="16" />
            </button>
            <div v-if="menuOpen" class="owner-menu" @click="menuOpen = false">
              <button class="owner-menu-item" @click="startEdit">
                Edit title & description
              </button>
              <button class="owner-menu-item owner-menu-danger" @click="doDelete">
                Delete video
              </button>
            </div>
          </div>
        </div>

        <div class="detail-author">
          <Avatar :username="video.username" size="md" />
          <div>
            <RouterLink :to="`/users/${video.username}`" class="detail-author-name">
              @{{ video.username }}
            </RouterLink>
            <p class="muted" style="margin: 0; font-size: 0.8rem;">
              <span v-if="video.published_at">{{ fmtTime(video.published_at) }}</span>
            </p>
          </div>

          <div style="margin-left: auto; display: flex; gap: 0.5rem; flex-wrap: wrap;">
            <button
              class="btn btn-sm"
              :class="{ 'btn-primary': liked }"
              :disabled="!me"
              @click="toggleLike"
            >
              <Icon name="heart" :size="14" />
              <span v-if="video.like_count > 0">
                {{ fmtCount(video.like_count) }} {{ video.like_count === 1 ? 'Like' : 'Likes' }}
              </span>
              <span v-else>Like</span>
            </button>

            <button
              class="btn btn-sm"
              :class="{ 'btn-primary': boosted }"
              :disabled="!me || boostBusy"
              @click="toggleBoost"
            >
              <Icon name="repeat" :size="14" />
              <span v-if="video.boost_count > 0">
                {{ fmtCount(video.boost_count) }} {{ video.boost_count === 1 ? 'Boost' : 'Boosts' }}
              </span>
              <span v-else>Boost</span>
            </button>

            <button class="btn btn-sm" @click="share">
              <Icon name="send" :size="14" /> Share
            </button>
          </div>
        </div>

        <!-- Edit form -->
        <div v-if="editing" class="card" style="margin-top: 1rem;">
          <h3 style="margin: 0 0 1rem;">Edit video</h3>

          <label class="label-text" for="ed-title">Title</label>
          <input id="ed-title" v-model="editTitle" maxlength="200" />

          <label class="label-text" for="ed-desc" style="margin-top: 1rem;">Description</label>
          <textarea id="ed-desc" v-model="editDescription" rows="4" maxlength="1000"></textarea>

          <div style="display: flex; gap: 0.5rem; margin-top: 1rem;">
            <button class="btn btn-primary" :disabled="editBusy" @click="saveEdit">
              {{ editBusy ? 'Saving…' : 'Save' }}
            </button>
            <button class="btn" :disabled="editBusy" @click="editing = false">Cancel</button>
          </div>

          <p v-if="editError" class="error" style="margin: 0.75rem 0 0;">{{ editError }}</p>
        </div>

        <p v-else-if="video.description" class="detail-description">{{ video.description }}</p>
        <div v-if="video.tags && video.tags.length" class="detail-tags">
          <RouterLink
            v-for="t in video.tags"
            :key="t"
            :to="`/local?tag=${encodeURIComponent(t)}`"
            class="detail-tag"
          >#{{ t }}</RouterLink>
        </div>

        <div class="detail-meta">
          <span v-if="video.duration">{{ Math.round(video.duration) }}s</span>
          <span v-if="video.width && video.height">{{ video.width }} × {{ video.height }}</span>
          <span v-if="video.comment_count > 0">
            {{ fmtCount(video.comment_count) }} {{ video.comment_count === 1 ? 'comment' : 'comments' }}
          </span>
          <span class="badge" :class="`badge-${video.transcode_status}`">
            {{ video.transcode_status }}
          </span>
        </div>
      </div>

      <div id="comments" class="card">
        <Comments :username="video.username" :video-id="video.id" />
      </div>
    </template>
  </div>
</template>

<style scoped>
.detail-author {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    padding: 1rem 0;
    border-top: 1px solid #232833;
    border-bottom: 1px solid #232833;
    flex-wrap: wrap;
}
html:not(.dark) .detail-author { border-color: #e7e7ec; }

.detail-author-name {
    color: #f4f4f7;
    font-weight: 700;
    font-size: 0.95rem;
    text-decoration: none;
}
.detail-author-name:hover { color: #8b5cf6; }
html:not(.dark) .detail-author-name { color: #0e0f14; }

.detail-description {
    margin: 1rem 0;
    color: #a1a7b3;
    font-size: 0.95rem;
    line-height: 1.6;
    white-space: pre-wrap;
}

.detail-meta {
    display: flex;
    gap: 1rem;
    align-items: center;
    flex-wrap: wrap;
    font-size: 0.85rem;
    color: #6a7180;
}

.owner-menu {
    position: absolute;
    top: calc(100% + 0.5rem);
    right: 0;
    min-width: 220px;
    background: #14171f;
    border: 1px solid #232833;
    border-radius: 12px;
    padding: 0.4rem;
    box-shadow: 0 12px 32px rgba(0, 0, 0, 0.5);
    display: flex;
    flex-direction: column;
    z-index: 10;
}
.owner-menu-item {
    padding: 0.55rem 0.75rem;
    background: transparent;
    border: 0;
    color: #f4f4f7;
    text-align: left;
    font-family: inherit;
    font-size: 0.88rem;
    font-weight: 500;
    border-radius: 8px;
    cursor: pointer;
}
.owner-menu-item:hover { background: #252a35; }
.owner-menu-danger { color: #ef4444; }

.detail-tags {
    display: flex;
    flex-wrap: wrap;
    gap: 0.4rem;
    margin: 0.75rem 0 1rem;
}
.detail-tag {
    display: inline-block;
    padding: 0.25rem 0.65rem;
    background: rgba(139, 92, 246, 0.1);
    color: #8b5cf6;
    border-radius: 8px;
    font-size: 0.8rem;
    font-weight: 600;
    text-decoration: none;
    transition: background 0.15s;
}
.detail-tag:hover { background: rgba(139, 92, 246, 0.2); }
</style>
