<script setup>
import { ref, onMounted, computed } from 'vue'
import { useRouter, RouterLink } from 'vue-router'
import { getSession, listFollowing, unfollow } from '../api'
import Icon from '../components/Icon.vue'
import Avatar from '../components/Avatar.vue'

const router = useRouter()
const me = ref(null)
const items = ref([])
const loading = ref(true)
const error = ref(null)
const busyActor = ref(null)

async function load() {
  loading.value = true
  error.value = null
  try {
    const sess = await getSession()
    if (!sess) { router.push('/login'); return }
    me.value = sess
    const data = await listFollowing(sess.username)
    items.value = data.items || []
  } catch (e) {
    error.value = e.message
  } finally {
    loading.value = false
  }
}

function shortActor(actor) {
  if (!actor) return 'unknown'
  const local = actor.match(/^https?:\/\/[^/]+\/users\/([^\/]+)$/)
  if (local) return local[1]
  return '@' + actor.replace(/^https?:\/\//, '')
}

async function doUnfollow(actor) {
  if (!confirm(`Unfollow ${shortActor(actor)}?`)) return
  busyActor.value = actor
  try {
    await unfollow(me.value.username, actor)
    items.value = items.value.filter(i => i.remote_actor !== actor)
  } catch (e) {
    error.value = e.message
  } finally {
    busyActor.value = null
  }
}

onMounted(load)
</script>

<template>
  <div class="stack">
    <div>
      <h1>Following</h1>
      <p class="muted">Accounts you follow across the Fediverse.</p>
    </div>

    <p v-if="loading" class="loading">Loading…</p>
    <p v-else-if="error" class="error">{{ error }}</p>

    <div v-else-if="items.length === 0" class="empty">
      <Icon name="users" :size="32" style="margin: 0 auto 0.75rem; display: block; color: #6a7180;" />
      <p style="margin: 0;">You aren't following anyone yet.</p>
      <p class="muted" style="margin: 0.25rem 0 0;">
        <RouterLink to="/explore">Find people on the Fediverse</RouterLink>
      </p>
    </div>

    <div v-else class="following-list">
      <div v-for="f in items" :key="f.remote_actor" class="following-row">
        <Avatar :username="shortActor(f.remote_actor)" size="md" />
        <div class="following-body">
          <RouterLink
            :to="`/users/${encodeURIComponent(shortActor(f.remote_actor))}`"
            class="following-name"
          >@{{ shortActor(f.remote_actor) }}</RouterLink>
          <p class="following-meta muted">
            <span v-if="f.accepted" class="badge badge-success" style="margin-right: 0.5rem;">accepted</span>
            <span v-else class="badge badge-warning" style="margin-right: 0.5rem;">pending</span>
            followed {{ new Date(f.created_at).toLocaleDateString() }}
          </p>
        </div>
        <button
          class="btn btn-sm btn-ghost btn-danger"
          :disabled="busyActor === f.remote_actor"
          @click="doUnfollow(f.remote_actor)"
        >
          {{ busyActor === f.remote_actor ? '…' : 'Unfollow' }}
        </button>
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
    color: #8b5cf6;
    text-decoration: none;
    margin-bottom: 0.15rem;
}
.following-name:hover { text-decoration: underline; }
.following-meta {
    display: flex;
    align-items: center;
    gap: 0.35rem;
    margin: 0;
    font-size: 0.8rem;
}
</style>
