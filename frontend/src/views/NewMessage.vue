<script setup>
import { ref, onMounted } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { getSession, sendMessage } from '../api'
import Icon from '../components/Icon.vue'

const router = useRouter()
const route = useRoute()
const me = ref(null)
const to = ref(route.query.to || '')
const body = ref('')
const busy = ref(false)
const error = ref(null)

onMounted(async () => {
  const sess = await getSession()
  if (!sess) { router.push('/login'); return }
  me.value = sess
})

function localSlug(recipient) {
  // "alice"           -> "alice"
  // "@alice"          -> "alice"
  // "@alice@host"     -> "alice"
  // "alice@host"      -> "alice"
  // "https://host/users/alice" -> "alice"
  let s = recipient.trim()
  if (s.startsWith('http://') || s.startsWith('https://')) {
    const m = s.match(/\/users\/([^\/]+)/)
    return m ? m[1] : s
  }
  s = s.replace(/^@/, '')
  const at = s.indexOf('@')
  if (at >= 0) s = s.slice(0, at)
  return s
}

async function submit() {
  error.value = null
  const recipient = to.value.trim()
  if (!recipient) { error.value = 'Enter a recipient'; return }
  if (!body.value.trim()) { error.value = 'Message is empty'; return }

  busy.value = true
  try {
    await sendMessage(me.value.username, recipient, body.value.trim())
    router.push(`/messages/thread/${localSlug(recipient)}`)
  } catch (e) {
    error.value = e.message
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div class="stack">
    <div>
      <h1>New message</h1>
      <p class="muted">Send a direct message to anyone on the Fediverse.</p>
    </div>

    <form @submit.prevent="submit" class="card" style="display: flex; flex-direction: column; gap: 1.25rem;">
      <div>
        <label class="label-text" for="nm-to">To</label>
        <input
          id="nm-to"
          v-model="to"
          type="text"
          placeholder="@bob@example.com or alice"
          required
          autocomplete="off"
        />
        <p class="muted" style="font-size: 0.78rem; margin: 0.4rem 0 0;">
          Local user (<code class="mono">alice</code>), handle (<code class="mono">@bob@other.instance</code>),
          or actor URL.
        </p>
      </div>

      <div>
        <label class="label-text" for="nm-body">Message</label>
        <textarea
          id="nm-body"
          v-model="body"
          rows="5"
          maxlength="5000"
          placeholder="Write your message…"
          required
        ></textarea>
      </div>

      <button type="submit" class="btn btn-primary" :disabled="busy" style="padding: 0.85rem;">
        <Icon name="send" :size="16" />
        {{ busy ? 'Sending…' : 'Send' }}
      </button>

      <p v-if="error" class="error" style="text-align: center; margin: 0;">{{ error }}</p>
    </form>
  </div>
</template>
