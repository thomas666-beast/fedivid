<script setup>
import { ref, onMounted } from 'vue'
import { useRouter, RouterLink } from 'vue-router'
import { getSession } from '../api'
import Icon from '../components/Icon.vue'

const router = useRouter()
const username = ref('')
const password = ref('')
const confirm  = ref('')
const error    = ref(null)
const busy     = ref(false)
const checking = ref(true)

onMounted(async () => {
  const sess = await getSession()
  if (sess) {
    router.replace(`/users/${sess.username}`)
    return
  }
  checking.value = false
})

async function submit() {
  error.value = null

  if (!/^[a-z0-9_]{3,30}$/.test(username.value)) {
    error.value = 'Username must be 3-30 characters: lowercase, digits, underscore'
    return
  }
  if (password.value.length < 8) {
    error.value = 'Password must be at least 8 characters'
    return
  }
  if (password.value !== confirm.value) {
    error.value = 'Passwords do not match'
    return
  }

  busy.value = true
  try {
    const res = await fetch('/api/users', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'include',
      body: JSON.stringify({
        username: username.value,
        password: password.value,
      }),
    })
    const body = await res.json().catch(() => ({}))

    if (!res.ok) {
      error.value = body.message || body.error || `HTTP ${res.status}`
      return
    }

    // Auto-login after signup
    const loginRes = await fetch('/api/sessions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'include',
      body: JSON.stringify({
        username: username.value,
        password: password.value,
      }),
    })

    if (loginRes.ok) {
      router.replace(`/users/${username.value}`)
    } else {
      router.replace('/login')
    }
  } catch (e) {
    error.value = e.message
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div v-if="!checking" style="min-height: 70vh; display: flex; align-items: center; justify-content: center; padding: 2rem 1rem;">
    <div style="width: 100%; max-width: 24rem;">

      <div style="display: flex; justify-content: center; margin-bottom: 1.75rem;">
        <div style="width: 3.5rem; height: 3.5rem; border-radius: 1rem; background: linear-gradient(135deg, #8b5cf6, #d946ef); display: flex; align-items: center; justify-content: center; box-shadow: 0 12px 32px rgba(139, 92, 246, 0.4);">
          <Icon name="play" :size="26" style="color: white;" />
        </div>
      </div>

      <h1 style="font-size: 1.6rem; font-weight: 800; text-align: center; margin: 0 0 0.5rem; letter-spacing: -0.02em;">
        Create your account
      </h1>
      <p class="muted" style="text-align: center; margin: 0 0 2rem;">
        Join this FediVid instance.
      </p>

      <form
        @submit.prevent="submit"
        class="card"
        style="display: flex; flex-direction: column; gap: 1.25rem;"
      >
        <div>
          <label class="label-text" for="su-user">Username</label>
          <input
            id="su-user"
            v-model="username"
            type="text"
            autocomplete="username"
            required
            placeholder="alice"
          />
          <p class="muted" style="font-size: 0.78rem; margin: 0.4rem 0 0;">
            Lowercase letters, digits, underscore. 3–30 characters.
          </p>
        </div>

        <div>
          <label class="label-text" for="su-pass">Password</label>
          <input
            id="su-pass"
            v-model="password"
            type="password"
            autocomplete="new-password"
            required
            minlength="8"
            placeholder="at least 8 characters"
          />
        </div>

        <div>
          <label class="label-text" for="su-confirm">Confirm password</label>
          <input
            id="su-confirm"
            v-model="confirm"
            type="password"
            autocomplete="new-password"
            required
            minlength="8"
            placeholder="repeat your password"
          />
        </div>

        <button
          type="submit"
          class="btn btn-primary"
          :disabled="busy"
          style="width: 100%; padding: 0.85rem; font-size: 0.95rem;"
        >
          {{ busy ? 'Creating account…' : 'Sign up' }}
        </button>

        <p v-if="error" class="error" style="text-align: center; margin: 0;">{{ error }}</p>

        <p class="muted" style="text-align: center; margin: 0;">
          Already have an account?
          <RouterLink to="/login" style="color: #8b5cf6; font-weight: 600;">Log in</RouterLink>
        </p>
      </form>

      <p class="muted" style="text-align: center; margin-top: 1.25rem;">
        <RouterLink to="/about" style="color: #8b5cf6;">About this instance</RouterLink>
      </p>
    </div>
  </div>
</template>
