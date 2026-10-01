<script setup>
import { ref, onMounted, computed, watch } from 'vue'
import { useRoute, RouterLink } from 'vue-router'
import { getSession, getLocalFeed } from '../api'
import VideoPreviewCard from '../components/VideoPreviewCard.vue'
import Icon from '../components/Icon.vue'
import { useInfiniteScroll } from '../composables/useInfiniteScroll'

const route = useRoute()
const items = ref([])
const error = ref(null)
const cursor = ref(null)
const myBoosts = ref(new Set())

const activeTag = computed(() => route.query.tag || null)

async function loadPage() {
  const data = await getLocalFeed(cursor.value, 50, activeTag.value)
  const seen = new Set(items.value.map(i => `${i.source || 'local'}-${i.id}`))
  for (const item of (data.items || [])) {
    const key = `${item.source || 'local'}-${item.id}`
    if (!seen.has(key)) {
      items.value.push(item)
      seen.add(key)
    }
  }
  cursor.value = data.next_cursor
  return !!data.next_cursor
}

const { sentinel, loading, done, markReady } = useInfiniteScroll(loadPage)

async function reset() {
  items.value = []
  cursor.value = null
  done.value = false
}

onMounted(async () => {
  try {
    const sess = await getSession()
    if (sess) {
      const list = await fetch(
        `/api/users/${encodeURIComponent(sess.username)}/announces`,
        { credentials: 'include' }
      ).then(r => r.json())
      myBoosts.value = new Set((list.items || []).map(a => a.object))
    }
    await loadPage()
    markReady()
  } catch (e) {
    error.value = e.message
  }
})

watch(activeTag, async () => {
  await reset()
  await loadPage()
})

function onBoostToggled({ url, boosted }) {
  const next = new Set(myBoosts.value)
  if (boosted) next.add(url)
  else next.delete(url)
  myBoosts.value = next
}
</script>

<template>
  <div class="stack">
    <div>
      <h1>Local</h1>
      <p class="muted" v-if="!activeTag">Videos from everyone on this instance.</p>
      <p class="muted" v-else>
        Videos tagged
        <span class="tag-pill">#{{ activeTag }}</span>
        <RouterLink to="/local" class="clear-link">clear filter</RouterLink>
      </p>
    </div>

    <p v-if="error" class="error">{{ error }}</p>
    <div v-if="items.length === 0 && !loading" class="empty">
      <span v-if="activeTag">No videos tagged #{{ activeTag }}.</span>
      <span v-else>No videos on this instance yet.</span>
    </div>

    <div v-else class="feed">
      <VideoPreviewCard
        v-for="v in items"
        :key="v.id"
        :video="v"
        :username="v.username"
        :boosted="myBoosts.has(v.url)"
        @boost-toggled="onBoostToggled"
      />
    </div>

    <div ref="sentinel" class="sentinel"></div>
    <p v-if="loading" class="loading">Loading more…</p>
    <p v-if="done && items.length > 0" class="muted" style="text-align: center;">You've reached the end.</p>
  </div>
</template>

<style scoped>
.feed { display: grid; gap: 1.5rem; }
@media (min-width: 760px) {
    .feed { grid-template-columns: 1fr 1fr; }
}
.sentinel { height: 1px; }

.tag-pill {
    display: inline-block;
    padding: 0.1rem 0.5rem;
    background: rgba(139, 92, 246, 0.1);
    color: #8b5cf6;
    border-radius: 6px;
    font-weight: 600;
}
.clear-link {
    color: #8b5cf6;
    margin-left: 0.75rem;
    font-size: 0.85rem;
    text-decoration: none;
}
.clear-link:hover { text-decoration: underline; }
</style>
