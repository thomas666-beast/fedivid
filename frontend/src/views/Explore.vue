<script setup>
import { ref, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import { getSession, followHandle, search } from '../api'
import Icon from '../components/Icon.vue'

const router = useRouter()

const me = ref(null)
const q = ref('')

const followHandleInput = ref('')
const followBusy = ref(false)
const followMsg = ref(null)
const followErr = ref(null)

onMounted(async () => {
  me.value = await getSession()
})

function searchSubmit() {
  if (q.value.length >= 2) router.push({ path: '/search', query: { q: q.value } })
}

async function submitFollow() {
  followMsg.value = null
  followErr.value = null

  if (!me.value) {
    followErr.value = 'Log in first'
    return
  }

  const handle = followHandleInput.value.trim()
  if (!handle) return

  followBusy.value = true
  try {
    const result = await followHandle(me.value.username, handle)
    followMsg.value = result.status === 'accepted'
      ? `Followed ${handle}`
      : `Follow request sent to ${handle} (pending Accept)`
    followHandleInput.value = ''
  } catch (e) {
    followErr.value = e.message
  } finally {
    followBusy.value = false
  }
}
</script>

<template>
  <div class="stack">
    <div>
      <h1>Explore</h1>
      <p class="muted">Find videos, people, and other instances.</p>
    </div>

    <!-- Search -->
    <div class="card" style="display: flex; gap: 0.5rem;">
      <input
        v-model="q"
        type="search"
        placeholder="Search videos, users, comments…"
        @keyup.enter="searchSubmit"
      />
      <button class="btn btn-primary" :disabled="q.length < 2" @click="searchSubmit">
        <Icon name="search" :size="16" />
      </button>
    </div>

    <!-- Follow remote -->
    <div class="card">
      <h3 style="margin: 0 0 0.5rem;">Follow someone</h3>
      <p class="muted" style="margin: 0 0 1rem;">
        Paste a local username, a handle like <code class="mono">@bob@other.instance</code>,
        or a profile URL.
      </p>

      <div style="display: flex; gap: 0.5rem;">
        <input
          v-model="followHandleInput"
          type="text"
          placeholder="@bob@mastodon.social"
          :disabled="!me || followBusy"
          @keyup.enter="submitFollow"
        />
        <button
          class="btn btn-primary"
          :disabled="!me || !followHandleInput.trim() || followBusy"
          @click="submitFollow"
        >
          <Icon name="users" :size="16" />
          {{ followBusy ? 'Following…' : 'Follow' }}
        </button>
      </div>

      <p v-if="!me" class="muted" style="margin: 0.75rem 0 0;">
        <RouterLink to="/login">Log in</RouterLink> to follow people.
      </p>
      <p v-if="followMsg" style="margin: 0.75rem 0 0; color: #22c55e;">{{ followMsg }}</p>
      <p v-if="followErr" class="error" style="margin: 0.75rem 0 0;">{{ followErr }}</p>
    </div>

    <!-- Placeholders -->
    <div class="card">
      <h3 style="margin: 0 0 0.5rem;">Discover</h3>
      <p class="muted" style="margin: 0;">
        Trending videos, suggested accounts, and instance stats coming in a later task.
      </p>
    </div>
  </div>
</template>

<style scoped>
.card + .card { margin-top: 1rem; }
</style>
