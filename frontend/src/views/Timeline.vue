<script setup>
import { ref, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import { getSession, getTimeline } from '../api'
import VideoPreviewCard from '../components/VideoPreviewCard.vue'
import Icon from '../components/Icon.vue'
import { useInfiniteScroll } from '../composables/useInfiniteScroll'

const router = useRouter()
const items = ref([])
const error = ref(null)
const cursor = ref(null)
const me = ref(null)
const myBoosts = ref(new Set())

async function loadPage() {
  if (!me.value) return false
  const data = await getTimeline(me.value.username, cursor.value, 50)
  items.value.push(...(data.items || []))
  cursor.value = data.next_cursor
  return !!data.next_cursor
}

const { sentinel, loading, done } = useInfiniteScroll(loadPage)

onMounted(async () => {
  const sess = await getSession()
  if (!sess) { router.push('/login'); return }
  me.value = sess

  try {
    const list = await fetch(
      `/api/users/${encodeURIComponent(sess.username)}/announces`,
      { credentials: 'include' }
    ).then(r => r.json())
    myBoosts.value = new Set((list.items || []).map(a => a.object))
  } catch { /* ignore */ }

  await loadPage()
})

function onBoostToggled({ url, boosted }) {
  const next = new Set(myBoosts.value)
  if (boosted) next.add(url)
  else next.delete(url)
  myBoosts.value = next
}

function videoOf(item) {
  return item.source === 'boost' ? item.video : item
}
</script>

<template>
  <div class="stack">
    <div>
      <h1>Home</h1>
      <p class="muted">Videos and boosts from people you follow.</p>
    </div>

    <p v-if="error" class="error">{{ error }}</p>

    <div v-if="items.length === 0 && !loading" class="empty">
      <Icon name="play" :size="32" style="margin: 0 auto 0.75rem; display: block; color: #6a7180;" />
      <p style="margin: 0;">Nothing here yet.</p>
      <p class="muted" style="margin: 0.25rem 0 0;">Follow some people, or upload a video.</p>
    </div>

    <div v-else class="feed">
      <div v-for="item in items" :key="`${item.source}-${item.id}`" class="feed-item">
        <div v-if="item.source === 'boost'" class="boost-header">
          <Icon name="repeat" :size="14" />
          <span>Boosted by</span>
          <RouterLink :to="`/users/${item.boosted_by}`" class="boost-user">
            @{{ item.boosted_by }}
          </RouterLink>
        </div>

        <VideoPreviewCard
          :video="videoOf(item)"
          :username="videoOf(item).username"
          :boosted="myBoosts.has(videoOf(item).url)"
          @boost-toggled="onBoostToggled"
        />
      </div>
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

.feed-item {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
}

.boost-header {
    display: flex;
    align-items: center;
    gap: 0.4rem;
    padding-left: 0.5rem;
    font-size: 0.82rem;
    color: #6a7180;
}
.boost-user {
    color: #8b5cf6;
    font-weight: 700;
    text-decoration: none;
}
.boost-user:hover { text-decoration: underline; }

.sentinel { height: 1px; }
</style>
