<script setup>
import { ref, computed, onMounted } from 'vue'
import { RouterLink } from 'vue-router'
import Icon from './Icon.vue'
import Avatar from './Avatar.vue'
import { getSession, likeVideo, unlikeVideo, likeStatus, boost, unboost } from '../api'
import { fmtCount } from '../utils/format'

const props = defineProps({
  video: { type: Object, required: true },
  username: { type: String, required: true },
  boosted: { type: Boolean, default: false },
})

const emit = defineEmits(['boost-toggled'])
const posterFailed = ref(false)

const me = ref(null)
const liked = ref(false)
const likeCount = ref(props.video.like_count || 0)
const boostCount = ref(props.video.boost_count || 0)
const boostBusy = ref(false)

const videoLink = computed(() => {
  if (props.video.source === 'local' || !props.video.source) {
    return `/u/${props.username}/v/${props.video.id}`
  }
  return `/v/${props.video.id}`
})

// Display handle: for remote "@localhost:3000/users/alice" → "@alice@localhost:3000"
// for local "alice" → "alice"
const displayName = computed(() => {
  const u = props.username || ''
  if (u.includes('/users/')) {
    const [host, user] = u.replace(/^@/, '').split('/users/')
    return `${user}@${host}`
  }
  return u.replace(/^@/, '')
})

const authorLink = computed(() => {
  const u = props.username || ''

  // Remote: "@localhost:3000/users/alice" → "/remote/alice@localhost:3000"
  if (u.includes('/users/')) {
    const [host, user] = u.replace(/^@/, '').split('/users/')
    return `/remote/${user}@${host}`
  }

  // Local
  return `/users/${encodeURIComponent(u)}`
})

const durationLabel = computed(() => {
  const s = props.video.duration
  if (!s) return null
  const m = Math.floor(s / 60)
  const sec = Math.floor(s % 60).toString().padStart(2, '0')
  return `${m}:${sec}`
})

onMounted(async () => {
  me.value = await getSession()
  if (!me.value) return
  if (props.video.source === 'local' || !props.video.source) {
    try {
      const status = await likeStatus(me.value.username, props.video.id)
      liked.value = !!status.liked
      likeCount.value = status.count
    } catch { /* ignore */ }
  }
})

async function toggleLike() {
  if (!me.value) return
  // Like on remote videos not supported yet
  if (props.video.source && props.video.source !== 'local') return

  if (liked.value) {
    liked.value = false
    likeCount.value = Math.max(0, likeCount.value - 1)
    try { await unlikeVideo(me.value.username, props.video.id) } catch { /* ignore */ }
  } else {
    liked.value = true
    likeCount.value += 1
    try { await likeVideo(me.value.username, props.video.id) } catch { /* ignore */ }
  }
}

async function toggleBoost() {
  if (!me.value || boostBusy.value) return

  boostBusy.value = true

  // Boost by URL — works for both local and remote videos
  const objectUrl = props.video.url || props.video.object_id
  if (!objectUrl) {
    boostBusy.value = false
    return
  }

  if (props.boosted) {
    boostCount.value = Math.max(0, boostCount.value - 1)
    emit('boost-toggled', { url: objectUrl, boosted: false })
    try {
      await unboost(me.value.username, objectUrl)
    } catch {
      boostCount.value += 1
      emit('boost-toggled', { url: objectUrl, boosted: true })
    }
  } else {
    boostCount.value += 1
    emit('boost-toggled', { url: objectUrl, boosted: true })
    try {
      await boost(me.value.username, objectUrl)
    } catch {
      boostCount.value = Math.max(0, boostCount.value - 1)
      emit('boost-toggled', { url: objectUrl, boosted: false })
    }
  }

  boostBusy.value = false
}

async function share() {
  const url = `${window.location.origin}${videoLink.value}`
  try { await navigator.clipboard.writeText(url) } catch { /* ignore */ }
}
</script>

<template>
  <article class="vpc">
    <RouterLink :to="videoLink" class="vpc-poster">
      <img
        v-if="video.poster_url"
        :src="video.poster_url"
        alt=""
        class="vpc-poster-img"
        loading="lazy"
        @error="posterFailed = true"
        v-show="!posterFailed"
      />
      <div v-if="!video.poster_url || posterFailed" class="vpc-poster-bg">
        <Icon name="play" :size="48" />
      </div>
      <div v-else class="vpc-poster-overlay">
        <Icon name="play" :size="48" />
      </div>
      <span v-if="durationLabel" class="vpc-duration">{{ durationLabel }}</span>
      <span v-if="video.transcode_status !== 'ready'" class="vpc-status">
        {{ video.transcode_status }}
      </span>
    </RouterLink>

    <div class="vpc-body">
      <RouterLink :to="videoLink" class="vpc-title">
        {{ video.title || '(untitled)' }}
      </RouterLink>

      <div class="vpc-author">
        <Avatar :username="username" size="sm" />
        <RouterLink :to="authorLink" class="vpc-author-name">
          @{{ displayName }}
        </RouterLink>
        <span v-if="video.published_at" class="vpc-dot">·</span>
        <span v-if="video.published_at" class="vpc-when">
          {{ new Date(video.published_at).toLocaleDateString() }}
        </span>
      </div>

      <p v-if="video.description" class="vpc-description">
        {{ video.description }}
      </p>

      <div v-if="video.tags && video.tags.length" class="vpc-tags">
        <RouterLink
          v-for="t in video.tags"
          :key="t"
          :to="`/local?tag=${encodeURIComponent(t)}`"
          class="vpc-tag"
        >#{{ t }}</RouterLink>
      </div>

      <div class="vpc-actions-wrap">
        <div class="vpc-actions">
          <button
            class="vpc-action"
            :class="{ active: liked }"
            :title="liked ? 'Unlike' : 'Like'"
            @click.stop="toggleLike"
          >
            <Icon name="heart" :size="15" />
            <span class="vpc-action-label">{{ likeCount > 0 ? fmtCount(likeCount) : 'Like' }}</span>
          </button>

          <button
            class="vpc-action"
            :class="{ active: boosted }"
            :disabled="boostBusy"
            :title="boosted ? 'Unboost' : 'Boost'"
            @click.stop="toggleBoost"
          >
            <Icon name="repeat" :size="15" />
            <span class="vpc-action-label">{{ boostCount > 0 ? fmtCount(boostCount) : 'Boost' }}</span>
          </button>

          <RouterLink :to="videoLink + '#comments'" class="vpc-action" title="Comment">
            <Icon name="comment" :size="15" />
            <span class="vpc-action-label">Comment</span>
          </RouterLink>

          <button class="vpc-action" title="Share" @click.stop="share">
            <Icon name="send" :size="15" />
            <span class="vpc-action-label">Share</span>
          </button>
        </div>
      </div>
    </div>
  </article>
</template>

<style scoped>
.vpc {
    display: flex; flex-direction: column;
    background: #101114; border: 1px solid #1e1f24;
    border-radius: 16px; overflow: hidden;
    transition: border-color 0.15s, transform 0.15s;
}
.vpc:hover { border-color: #2b2d34; transform: translateY(-1px); }
html:not(.dark) .vpc { background: #fafbfc; border-color: #dcdde1; }

.vpc-poster {
    position: relative; display: block;
    aspect-ratio: 16 / 9;
    background: linear-gradient(135deg, #17181c 0%, #2a1f4a 50%, #17181c 100%);
    text-decoration: none; overflow: hidden;
}
.vpc-poster-img {
    position: absolute; inset: 0;
    width: 100%; height: 100%;
    object-fit: cover;
    transition: transform 0.2s ease;
}
.vpc:hover .vpc-poster-img { transform: scale(1.05); }

.vpc-poster-bg {
    position: absolute; inset: 0;
    display: flex; align-items: center; justify-content: center;
    color: rgba(255, 255, 255, 0.3);
    transition: color 0.15s, transform 0.15s;
}
.vpc:hover .vpc-poster-bg { color: rgba(255, 255, 255, 0.6); transform: scale(1.05); }

.vpc-poster-overlay {
    position: absolute; inset: 0;
    display: flex; align-items: center; justify-content: center;
    background: rgba(0, 0, 0, 0.15);
    opacity: 0;
    transition: opacity 0.15s, background 0.15s;
    color: rgba(255, 255, 255, 0.9);
}
.vpc:hover .vpc-poster-overlay {
    opacity: 1;
    background: rgba(0, 0, 0, 0.35);
}

.vpc-duration {
    position: absolute; right: 0.6rem; bottom: 0.6rem;
    padding: 0.15rem 0.5rem; background: rgba(0, 0, 0, 0.75); color: white;
    font-size: 0.75rem; font-weight: 600; border-radius: 6px;
    font-family: ui-monospace, monospace;
}
.vpc-status {
    position: absolute; left: 0.6rem; top: 0.6rem;
    padding: 0.15rem 0.5rem;
    background: rgba(139, 92, 246, 0.9); color: white;
    font-size: 0.65rem; font-weight: 700; text-transform: uppercase;
    letter-spacing: 0.05em; border-radius: 6px;
}
.vpc-body { padding: 1rem 1.1rem 1.1rem; }
.vpc-title {
    display: block; color: #f5f6f8; font-size: 1.05rem; font-weight: 700;
    line-height: 1.3; letter-spacing: -0.01em; text-decoration: none;
    margin-bottom: 0.5rem;
}
.vpc-title:hover { color: #8b5cf6; }
html:not(.dark) .vpc-title { color: #1a1b22; }
.vpc-author {
    display: flex; align-items: center; gap: 0.5rem;
    font-size: 0.85rem; color: #9ca0a8; margin-bottom: 0.6rem;
}
.vpc-author-name { color: #9ca0a8; text-decoration: none; font-weight: 600; }
.vpc-author-name:hover { color: #8b5cf6; }
.vpc-dot, .vpc-when { color: #6a6e78; }
.vpc-description {
    margin: 0 0 0.85rem; color: #9ca0a8;
    font-size: 0.9rem; line-height: 1.5;
    display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical;
    overflow: hidden;
}

/* Actions row: the wrapper is a container for the query below */
.vpc-actions-wrap {
    container-type: inline-size;
    container-name: vpc-actions;
}
.vpc-actions {
    display: flex; gap: 0.25rem;
    padding-top: 0.75rem; border-top: 1px solid #1e1f24;
}
html:not(.dark) .vpc-actions { border-color: #dcdde1; }
.vpc-action {
    display: inline-flex; align-items: center; gap: 0.35rem;
    padding: 0.4rem 0.7rem; background: transparent; color: #9ca0a8;
    border: 0; border-radius: 8px; font-family: inherit;
    font-size: 0.82rem; font-weight: 600; text-decoration: none; cursor: pointer;
    transition: background 0.15s, color 0.15s;
    white-space: nowrap;
}
.vpc-action:hover { background: #1f2025; color: #f5f6f8; }
.vpc-action.active { color: #8b5cf6; }
.vpc-action:disabled { opacity: 0.5; cursor: not-allowed; }
html:not(.dark) .vpc-action:hover { background: #e7e9ec; color: #1a1b22; }

/* When the card's inner width is too small for labels, hide them */
@container vpc-actions (max-width: 340px) {
    .vpc-action-label {
        display: none;
    }
    .vpc-action {
        padding: 0.4rem 0.55rem;
        gap: 0;
    }
}

.vpc-tags {
    display: flex;
    flex-wrap: wrap;
    gap: 0.35rem;
    margin-bottom: 0.75rem;
}
.vpc-tag {
    display: inline-block;
    padding: 0.15rem 0.5rem;
    background: rgba(139, 92, 246, 0.1);
    color: #8b5cf6;
    border-radius: 6px;
    font-size: 0.72rem;
    font-weight: 600;
    text-decoration: none;
    transition: background 0.15s;
}
.vpc-tag:hover { background: rgba(139, 92, 246, 0.2); }
</style>
