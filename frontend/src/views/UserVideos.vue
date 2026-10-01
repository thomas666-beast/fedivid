<script setup>
import { ref, onMounted, watch, computed } from 'vue'
import { listVideos, getProfile, getSession, follow, unfollow, uploadAvatar, deleteAvatar } from '../api'
import VideoPreviewCard from '../components/VideoPreviewCard.vue'
import Avatar from '../components/Avatar.vue'
import Icon from '../components/Icon.vue'
import { fmtCount } from '../utils/format'

import { useInfiniteScroll } from '../composables/useInfiniteScroll'

const cursor = ref(null)

async function loadMore() {
  const data = await listVideos(props.username, cursor.value, 50)
  items.value.push(...(data.items || []))
  cursor.value = data.next_cursor
  return !!data.next_cursor
}

const { sentinel, loading: loadingMore, done } = useInfiniteScroll(loadMore)

const props = defineProps({ username: String })

const items = ref([])
const profile = ref(null)
const me = ref(null)
const loading = ref(false)
const error = ref(null)
const followBusy = ref(false)
const myBoosts = ref(new Set())

const isSelf = computed(() => me.value && me.value.username === props.username)
const canFollow = computed(() => profile.value && me.value && !isSelf.value)

async function onAvatarPick(e) {
  const file = e.target.files[0]
  if (!file) return
  try {
    await uploadAvatar(me.value.username, file)
    window.location.reload()
  } catch (err) {
    alert(err.message)
  }
}

async function removeAvatar() {
  if (!confirm('Remove your avatar?')) return
  try {
    await deleteAvatar(me.value.username)
    window.location.reload()
  } catch (err) {
    alert(err.message)
  }
}

async function load() {
  loading.value = true
  error.value = null
  try {
    const [data, prof, sess] = await Promise.all([
      listVideos(props.username, null, 50),
      getProfile(props.username),
      getSession(),
    ])
    items.value = data.items || []
    cursor.value = data.next_cursor
    profile.value = prof
    me.value = sess

    if (sess) {
      try {
        const list = await fetch(
          `/api/users/${encodeURIComponent(sess.username)}/announces`,
          { credentials: 'include' }
        ).then(r => r.json())
        myBoosts.value = new Set((list.items || []).map(a => a.object))
      } catch { /* ignore */ }
    }
  } catch (e) {
    error.value = e.message
  } finally {
    loading.value = false
  }
}

function onBoostToggled({ url, boosted }) {
  const next = new Set(myBoosts.value)
  if (boosted) next.add(url)
  else next.delete(url)
  myBoosts.value = next
}

async function toggleFollow() {
  followBusy.value = true
  try {
    if (profile.value.you_follow) {
      await unfollow(me.value.username, profile.value.actor_id)
      profile.value.you_follow = 0
      profile.value.followers_count = Math.max(0, profile.value.followers_count - 1)
    } else {
      await follow(me.value.username, profile.value.actor_id)
      profile.value.you_follow = 1
      profile.value.followers_count += 1
    }
  } catch (err) {
    alert(err.message)
  } finally {
    followBusy.value = false
  }
}

onMounted(load)
watch(() => props.username, load)
</script>

<template>
  <div class="stack-lg">
    <header v-if="profile" class="profile-card">

      <div class="profile-top">
        <Avatar :username="username" size="lg" />

        <div class="profile-body">
          <h1 class="profile-name">@{{ username }}</h1>

          <div class="profile-stats">
            <div class="stat">
              <div class="stat-value">{{ fmtCount(profile.video_count) }}</div>
              <div class="stat-label">Videos</div>
            </div>
            <RouterLink :to="`/users/${username}/followers`" class="stat stat-link">
              <div class="stat-value">{{ fmtCount(profile.followers_count) }}</div>
              <div class="stat-label">Followers</div>
            </RouterLink>
            <RouterLink v-if="isSelf" to="/following" class="stat stat-link">
              <div class="stat-value">{{ fmtCount(profile.following_count) }}</div>
              <div class="stat-label">Following</div>
            </RouterLink>
            <div v-else class="stat">
              <div class="stat-value">{{ fmtCount(profile.following_count) }}</div>
              <div class="stat-label">Following</div>
            </div>
          </div>
        </div>
      </div>

      <!-- Subscribe -->
      <div class="subscribe-row">
        <a
          :href="`/users/${username}/feed.xml`"
          class="rss-btn"
          title="Subscribe via RSS"
          target="_blank"
          rel="noopener"
        >
          <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
            <circle cx="6.18" cy="17.82" r="2.18"/>
            <path d="M4 4.44v2.83c7.03 0 12.73 5.7 12.73 12.73h2.83c0-8.59-6.97-15.56-15.56-15.56zm0 5.66v2.83c3.9 0 7.07 3.17 7.07 7.07h2.83c0-5.47-4.43-9.9-9.9-9.9z"/>
          </svg>
          <span>RSS feed</span>
        </a>
      </div>

      <div v-if="me && !isSelf" class="profile-actions">
        <button
          v-if="canFollow"
          class="btn"
          :class="profile.you_follow ? '' : 'btn-primary'"
          :disabled="followBusy"
          @click="toggleFollow"
        >
          <Icon :name="profile.you_follow ? 'check' : 'users'" :size="16" />
          {{ profile.you_follow ? 'Following' : 'Follow' }}
        </button>

        <RouterLink :to="`/messages/new?to=${encodeURIComponent(username)}`" class="btn">
          <Icon name="message" :size="16" />
          Message
        </RouterLink>
      </div>

      <div v-if="isSelf" class="profile-actions">
        <label class="btn">
          <Icon name="user" :size="16" />
          Change avatar
          <input
            type="file"
            accept="image/jpeg,image/png,image/webp"
            style="display: none;"
            @change="onAvatarPick"
          />
        </label>
        <RouterLink to="/upload" class="btn btn-primary">
          <Icon name="upload" :size="16" />
          Upload video
        </RouterLink>
        <button class="btn btn-ghost btn-danger" @click="removeAvatar">
          Remove avatar
        </button>
      </div>
    </header>

    <p v-if="loading" class="loading">Loading…</p>
    <p v-else-if="error" class="error">{{ error }}</p>
    <div v-else-if="items.length === 0" class="empty">No videos yet.</div>

    <div v-else class="feed">
      <VideoPreviewCard
        v-for="v in items"
        :key="v.id"
        :video="v"
        :username="username"
        :boosted="myBoosts.has(v.url)"
        @boost-toggled="onBoostToggled"
      />
    </div>

    <div ref="sentinel" class="sentinel"></div>
    <p v-if="loadingMore" class="loading">Loading more…</p>
    <p v-if="done && items.length > 0" class="muted" style="text-align: center;">You've reached the end.</p>
  </div>
</template>

<style scoped>
.stack-lg > * + * { margin-top: 2rem; }

.profile-card {
    display: flex;
    flex-direction: column;
    gap: 1.5rem;
    padding: 2rem;
    background: #14171f;
    border: 1px solid #232833;
    border-radius: 20px;
}
html:not(.dark) .profile-card { background: #fff; border-color: #e7e7ec; }

.profile-top {
    display: flex;
    align-items: center;
    gap: 1.5rem;
}

.profile-body { flex: 1; min-width: 0; }

.profile-name {
    margin: 0 0 1rem;
    font-size: 1.6rem;
    font-weight: 800;
    letter-spacing: -0.02em;
    word-break: break-word;
}

.profile-stats {
    display: flex;
    gap: 2rem;
    flex-wrap: wrap;
}

.stat {
    display: flex;
    flex-direction: column;
    gap: 0.15rem;
}

.stat-value {
    font-size: 1.15rem;
    font-weight: 700;
    color: #f4f4f7;
    line-height: 1;
}
html:not(.dark) .stat-value { color: #0e0f14; }

.stat-label {
    font-size: 0.72rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: #6a7180;
}

.stat-link {
    text-decoration: none;
    cursor: pointer;
}
.stat-link:hover .stat-value { color: #8b5cf6; }

.profile-actions {
    display: flex;
    gap: 0.5rem;
    flex-wrap: wrap;
    padding-top: 1.25rem;
    border-top: 1px solid #232833;
}
html:not(.dark) .profile-actions { border-color: #e7e7ec; }

.feed { display: grid; gap: 1.5rem; }
@media (min-width: 760px) {
    .feed { grid-template-columns: 1fr 1fr; }
}
.sentinel { height: 1px; }

.subscribe-row {
    display: flex;
    gap: 0.5rem;
    padding-top: 1.25rem;
    border-top: 1px solid #232833;
}
html:not(.dark) .subscribe-row { border-color: #e7e7ec; }

.rss-btn {
    display: inline-flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.45rem 0.9rem;
    background: transparent;
    border: 1px solid #232833;
    color: #a1a7b3;
    border-radius: 10px;
    font-size: 0.85rem;
    font-weight: 600;
    text-decoration: none;
    transition: all 0.15s;
}
.rss-btn:hover {
    color: #f59e0b;
    border-color: rgba(245, 158, 11, 0.4);
    background: rgba(245, 158, 11, 0.08);
}
html:not(.dark) .rss-btn {
    border-color: #e7e7ec;
    color: #5a5f6d;
}
html:not(.dark) .rss-btn:hover {
    color: #d97706;
    border-color: rgba(217, 119, 6, 0.4);
    background: rgba(217, 119, 6, 0.06);
}

.subscribe-row {
    display: flex;
    gap: 0.5rem;
    padding-top: 1.25rem;
    border-top: 1px solid #232833;
    margin-top: 1.25rem;
}
html:not(.dark) .subscribe-row { border-color: #e7e7ec; }

.rss-btn {
    display: inline-flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.45rem 0.9rem;
    background: transparent;
    border: 1px solid #232833;
    color: #a1a7b3;
    border-radius: 10px;
    font-size: 0.85rem;
    font-weight: 600;
    text-decoration: none;
    transition: all 0.15s;
}
.rss-btn:hover {
    color: #f59e0b;
    border-color: rgba(245, 158, 11, 0.4);
    background: rgba(245, 158, 11, 0.08);
}
html:not(.dark) .rss-btn {
    border-color: #e7e7ec;
    color: #5a5f6d;
}
html:not(.dark) .rss-btn:hover {
    color: #d97706;
    border-color: rgba(217, 119, 6, 0.4);
    background: rgba(217, 119, 6, 0.06);
}
</style>
