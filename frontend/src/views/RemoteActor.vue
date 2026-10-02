<script setup>
import { ref, onMounted, watch, computed } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { getRemoteActor, getSession, follow, unfollow } from '../api'
import { fmtCount, fmtTime } from '../utils/format'
import VideoPreviewCard from '../components/VideoPreviewCard.vue'
import Icon from '../components/Icon.vue'

const route = useRoute()
const router = useRouter()

const actor = ref(null)
const me = ref(null)
const loading = ref(true)
const error = ref(null)
const followBusy = ref(false)
const isFollowing = ref(false)

const handle = computed(() => route.params.handle)

async function load() {
  loading.value = true
  error.value = null
  try {
    const [a, sess] = await Promise.all([
      getRemoteActor(handle.value),
      getSession(),
    ])
    if (!a) throw new Error('Actor not found')
    actor.value = a
    me.value = sess

    if (sess) {
      try {
        const list = await fetch(
          `/api/users/${encodeURIComponent(sess.username)}/following`,
          { credentials: 'include' }
        ).then(r => r.json())
        isFollowing.value = (list.items || []).some(
          i => i.remote_actor === a.actor_url
        )
      } catch { /* ignore */ }
    }
  } catch (e) {
    error.value = e.message
  } finally {
    loading.value = false
  }
}

async function toggleFollow() {
  if (!me.value || !actor.value) return
  followBusy.value = true
  error.value = null
  try {
    if (isFollowing.value) {
      await unfollow(me.value.username, actor.value.actor_url)
      isFollowing.value = false
    } else {
      await follow(me.value.username, actor.value.actor_url)
      isFollowing.value = true
    }
  } catch (e) {
    error.value = e.message
  } finally {
    followBusy.value = false
  }
}

onMounted(load)
watch(() => route.params.handle, load)
</script>

<template>
  <div class="stack">
    <button class="btn btn-ghost btn-sm" @click="router.back()">← Back</button>

    <p v-if="loading" class="loading">Loading…</p>
    <p v-else-if="error" class="error">{{ error }}</p>

    <template v-else-if="actor">
      <header class="remote-header">
        <div class="remote-avatar">
          {{ (actor.name || '?')[0].toUpperCase() }}
        </div>

        <div class="remote-body">
          <h1 class="remote-name">{{ actor.name }}</h1>
          <p class="remote-handle">{{ actor.handle }}</p>
          <p v-if="actor.video_count" class="remote-meta muted">
            {{ fmtCount(actor.video_count) }}
            {{ actor.video_count === 1 ? 'video' : 'videos' }}
          </p>
        </div>

        <div v-if="me" style="display: flex; gap: 0.5rem; flex-wrap: wrap;">
          <button
            class="btn"
            :class="isFollowing ? '' : 'btn-primary'"
            :disabled="followBusy"
            @click="toggleFollow"
          >
            {{ isFollowing ? 'Following' : 'Follow' }}
          </button>
          <a :href="actor.actor_url" target="_blank" rel="noopener" class="btn">
            <Icon name="send" :size="14" />
            View on remote
          </a>
        </div>
      </header>

      <!--
        Security note: the summary comes from a remote actor document that we do
        not control. It is rendered as plain text ({{ }}) so the browser escapes
        any HTML. Do NOT switch this to v-html without a proper sanitizer.
      -->
      <div v-if="actor.summary" class="remote-summary">{{ actor.summary }}</div>

      <div v-if="actor.videos.length === 0" class="empty">
        No videos cached from this account yet.
      </div>

      <div v-else class="feed">
        <VideoPreviewCard
          v-for="v in actor.videos"
          :key="v.id"
          :video="v"
          :username="v.username"
        />
      </div>
    </template>
  </div>
</template>

<style scoped>
.remote-header {
    display: flex;
    align-items: center;
    gap: 1.5rem;
    padding: 1.75rem;
    background: #14171f;
    border: 1px solid #232833;
    border-radius: 20px;
    flex-wrap: wrap;
}
html:not(.dark) .remote-header { background: #fff; border-color: #e7e7ec; }

.remote-avatar {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 72px;
    height: 72px;
    background: linear-gradient(135deg, #6366f1, #8b5cf6);
    color: white;
    border-radius: 9999px;
    font-weight: 800;
    font-size: 1.75rem;
    flex-shrink: 0;
}

.remote-body { flex: 1; min-width: 0; }
.remote-name {
    margin: 0 0 0.35rem;
    font-size: 1.5rem;
    font-weight: 800;
    letter-spacing: -0.02em;
    word-break: break-word;
}
.remote-handle {
    margin: 0 0 0.5rem;
    color: #8b5cf6;
    font-weight: 600;
    font-size: 0.9rem;
    word-break: break-all;
}
.remote-meta { margin: 0; font-size: 0.85rem; }

.remote-summary {
    padding: 1rem 1.25rem;
    background: #14171f;
    border: 1px solid #232833;
    border-radius: 14px;
    color: #a1a7b3;
    line-height: 1.6;
    white-space: pre-wrap;
    word-break: break-word;
}
html:not(.dark) .remote-summary { background: #fff; border-color: #e7e7ec; }

.feed { display: grid; gap: 1.25rem; }
@media (min-width: 640px) {
    .feed { grid-template-columns: 1fr 1fr; }
}
@media (min-width: 900px) {
    .feed { grid-template-columns: 1fr 1fr 1fr; }
}
@media (min-width: 1400px) {
    .feed { grid-template-columns: 1fr 1fr 1fr 1fr; }
}
</style>
