<script setup>
import { ref, onMounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { search } from '../api'
import Icon from '../components/Icon.vue'

const route = useRoute()
const router = useRouter()
const q = ref(route.query.q || '')
const results = ref(null)
const loading = ref(false)
const error = ref(null)

async function run() {
  if (!q.value || q.value.length < 2) { results.value = null; return }
  loading.value = true
  error.value = null
  try {
    results.value = await search(q.value)
  } catch (e) {
    error.value = e.message
    results.value = null
  } finally {
    loading.value = false
  }
}

function submit() {
  router.push({ path: '/search', query: { q: q.value } })
  run()
}

onMounted(run)
</script>

<template>
  <div class="stack">
    <div>
      <h1>Search</h1>
      <p class="muted">Videos, users, and comments.</p>
    </div>

    <form @submit.prevent="submit" style="display: flex; gap: 0.5rem;">
      <input
        v-model="q"
        type="search"
        minlength="2"
        placeholder="Search…"
        autofocus
        style="flex: 1;"
      />
      <button type="submit" class="btn btn-primary" :disabled="q.length < 2">
        <Icon name="search" :size="18" />
      </button>
    </form>

    <p v-if="loading" class="loading">Searching…</p>
    <p v-else-if="error" class="error">{{ error }}</p>

    <template v-else-if="results">
      <section v-if="results.users.length" class="stack-sm">
        <h3>Users</h3>
        <RouterLink
          v-for="u in results.users"
          :key="u.username"
          :to="`/users/${encodeURIComponent(u.username)}`"
          class="card"
          style="display: flex; align-items: center; gap: 0.75rem; color: inherit;"
        >
          <Icon name="user" :size="18" />
          <strong>{{ u.username }}</strong>
          <span class="muted">
            {{ u.video_count }} videos · {{ u.followers_count }} followers
          </span>
        </RouterLink>
      </section>

      <section v-if="results.videos.length" class="stack-sm">
        <h3>Videos</h3>
        <RouterLink
          v-for="v in results.videos"
          :key="v.id"
          :to="`/u/${encodeURIComponent(v.username)}/v/${v.id}`"
          class="card"
          style="display: flex; align-items: center; gap: 0.75rem; color: inherit;"
        >
          <Icon name="play" :size="18" />
          <strong>{{ v.title }}</strong>
          <span class="muted">by {{ v.username }}</span>
        </RouterLink>
      </section>

      <section v-if="results.comments.length" class="stack-sm">
        <h3>Comments</h3>
        <template v-for="c in results.comments" :key="c.id">
          <RouterLink
            v-if="c.video_id && c.video_user"
            :to="`/u/${encodeURIComponent(c.video_user)}/v/${c.video_id}`"
            class="card"
            style="display: block; color: inherit;"
          >
            <p style="margin: 0;">{{ c.body }}</p>
            <p class="muted" style="margin: 0.25rem 0 0;">
              by {{ c.username }} · on "{{ c.video_title || 'video' }}"
            </p>
          </RouterLink>
          <div v-else class="card">
            <p style="margin: 0;">{{ c.body }}</p>
            <p class="muted" style="margin: 0.25rem 0 0;">by {{ c.username }}</p>
          </div>
        </template>
      </section>

      <div
        v-if="!results.users.length && !results.videos.length && !results.comments.length"
        class="empty"
      >
        No results.
      </div>
    </template>
  </div>
</template>
