<script setup>
import { ref, onMounted } from 'vue'
import { useRouter, RouterLink } from 'vue-router'
import { login, getSession } from '../api'
import Icon from '../components/Icon.vue'

const router = useRouter()
const username = ref('')
const password = ref('')
const error = ref(null)
const busy = ref(false)
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
  busy.value = true
  try {
    await login(username.value, password.value)
    router.replace(`/users/${username.value}`)
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
        Welcome back
      </h1>
      <p class="muted" style="text-align: center; margin: 0 0 2rem;">
        Log in to upload, follow, and boost.
      </p>

      <form
        @submit.prevent="submit"
        class="card"
        style="display: flex; flex-direction: column; gap: 1.25rem;"
      >
        <div>
          <label class="label-text" for="login-user">Username</label>
          <input
            id="login-user"
            v-model="username"
            type="text"
            autocomplete="username"
            required
            placeholder="alice"
          />
        </div>

        <div>
          <label class="label-text" for="login-pass">Password</label>
          <input
            id="login-pass"
            v-model="password"
            type="password"
            autocomplete="current-password"
            required
            placeholder="••••••••"
          />
        </div>

        <button
          type="submit"
          class="btn btn-primary"
          :disabled="busy"
          style="width: 100%; padding: 0.85rem; font-size: 0.95rem;"
        >
          {{ busy ? 'Logging in…' : 'Log in' }}
        </button>

        <p v-if="error" class="error" style="text-align: center; margin: 0;">{{ error }}</p>
      </form>

      <p class="muted" style="text-align: center; margin-top: 1.25rem;">
        Don't have an account?
        <RouterLink to="/signup" style="color: #8b5cf6; font-weight: 600;">Sign up</RouterLink>
      </p>
    </div>
  </div>
</template>
