<script setup>
import { ref, onMounted, watch } from 'vue'
import { useRoute } from 'vue-router'
import { listFollowers } from '../api'
import Icon from '../components/Icon.vue'
import Avatar from '../components/Avatar.vue'

const route = useRoute()
const items = ref([])
const loading = ref(true)
const error = ref(null)

async function load() {
  loading.value = true
  error.value = null
  try {
    const data = await listFollowers(route.params.username)
    items.value = data.items || []
  } catch (e) {
    error.value = e.message
  } finally {
    loading.value = false
  }
}

onMounted(load)
watch(() => route.params.username, load)
</script>

<template>
  <div class="stack">
    <div>
      <h1>Followers of @{{ route.params.username }}</h1>
    </div>

    <p v-if="loading" class="loading">Loading…</p>
    <p v-else-if="error" class="error">{{ error }}</p>

    <div v-else-if="items.length === 0" class="empty">
      No followers yet.
    </div>

    <div v-else class="following-list">
      <div v-for="f in items" :key="f.actor" class="following-row">
        <Avatar :username="f.short" size="md" />
        <div class="following-body">
          <span class="following-name">@{{ f.short }}</span>
          <p class="following-meta muted">
            <span v-if="f.accepted" class="badge badge-success" style="margin-right: 0.5rem;">accepted</span>
            <span v-else class="badge badge-warning" style="margin-right: 0.5rem;">pending</span>
            since {{ new Date(f.created_at).toLocaleDateString() }}
          </p>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.following-list { display: flex; flex-direction: column; gap: 0.5rem; }
.following-row {
    display: flex;
    align-items: center;
    gap: 1rem;
    padding: 0.85rem 1.1rem;
    background: #14171f;
    border: 1px solid #232833;
    border-radius: 14px;
}
html:not(.dark) .following-row { background: #fff; border-color: #e7e7ec; }

.following-body { flex: 1; min-width: 0; }
.following-name {
    display: block;
    font-weight: 700;
    color: #f4f4f7;
    margin-bottom: 0.15rem;
}
html:not(.dark) .following-name { color: #0e0f14; }

.following-meta {
    display: flex;
    align-items: center;
    gap: 0.35rem;
    margin: 0;
    font-size: 0.8rem;
}
</style>
