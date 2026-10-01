<script setup>
import { ref, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import { getSession, changePassword, deleteAccount } from '../api'
import Icon from '../components/Icon.vue'

const router = useRouter()

const me = ref(null)
const loading = ref(true)

// Change password
const oldPassword = ref('')
const newPassword = ref('')
const confirmPassword = ref('')
const passBusy = ref(false)
const passMsg = ref(null)
const passErr = ref(null)

// Delete account
const deleteConfirm = ref('')
const deleteBusy = ref(false)
const deleteErr = ref(null)

onMounted(async () => {
  const sess = await getSession()
  if (!sess) { router.push('/login'); return }
  me.value = sess
  loading.value = false
})

async function submitPassword() {
  passMsg.value = null
  passErr.value = null

  if (newPassword.value.length < 8) {
    passErr.value = 'New password must be at least 8 characters'
    return
  }
  if (newPassword.value !== confirmPassword.value) {
    passErr.value = 'New passwords do not match'
    return
  }

  passBusy.value = true
  try {
    await changePassword(me.value.username, oldPassword.value, newPassword.value)
    passMsg.value = 'Password changed'
    oldPassword.value = ''
    newPassword.value = ''
    confirmPassword.value = ''
  } catch (e) {
    passErr.value = e.message
  } finally {
    passBusy.value = false
  }
}

async function submitDelete() {
  deleteErr.value = null
  if (deleteConfirm.value !== me.value.username) {
    deleteErr.value = 'Type your username exactly to confirm'
    return
  }
  if (!confirm('This will permanently delete your account and all your videos. Continue?')) return

  deleteBusy.value = true
  try {
    await deleteAccount(me.value.username)
    router.push('/')
  } catch (e) {
    deleteErr.value = e.message
  } finally {
    deleteBusy.value = false
  }
}
</script>

<template>
  <div class="stack">
    <div>
      <h1>Settings</h1>
      <p v-if="me" class="muted">Signed in as <strong>{{ me.username }}</strong>.</p>
    </div>

    <p v-if="loading" class="loading">Loading…</p>

    <template v-else-if="me">

      <!-- Change password -->
      <div class="card">
        <h3 style="margin: 0 0 0.5rem;">Change password</h3>
        <p class="muted" style="margin: 0 0 1rem;">
          Choose something long and unique. At least 8 characters.
        </p>

        <div class="form-row">
          <label class="label-text" for="old-pass">Current password</label>
          <input id="old-pass" v-model="oldPassword" type="password" autocomplete="current-password" />
        </div>

        <div class="form-row">
          <label class="label-text" for="new-pass">New password</label>
          <input id="new-pass" v-model="newPassword" type="password" autocomplete="new-password" minlength="8" />
        </div>

        <div class="form-row">
          <label class="label-text" for="confirm-pass">Confirm new password</label>
          <input id="confirm-pass" v-model="confirmPassword" type="password" autocomplete="new-password" minlength="8" />
        </div>

        <button class="btn btn-primary" :disabled="passBusy" @click="submitPassword" style="margin-top: 1rem;">
          {{ passBusy ? 'Saving…' : 'Change password' }}
        </button>

        <p v-if="passMsg" style="margin: 0.75rem 0 0; color: #22c55e;">{{ passMsg }}</p>
        <p v-if="passErr" class="error" style="margin: 0.75rem 0 0;">{{ passErr }}</p>
      </div>

      <!-- Log out -->
      <div class="card">
        <h3 style="margin: 0 0 0.5rem;">Session</h3>
        <p class="muted" style="margin: 0 0 1rem;">
          Log out of this browser. Your session cookie is cleared.
        </p>
        <button class="btn" @click="router.push('/logout')">Log out</button>
      </div>

      <!-- Delete account -->
      <div class="card" style="border-color: rgba(239, 68, 68, 0.4);">
        <h3 style="margin: 0 0 0.5rem; color: #ef4444;">Delete account</h3>
        <p class="muted" style="margin: 0 0 1rem;">
          This will permanently remove your account, all your videos, comments, messages, and any federated data.
          <strong>This cannot be undone.</strong>
        </p>

        <label class="label-text" for="del-confirm">
          Type <code class="mono">{{ me.username }}</code> to confirm
        </label>
        <input id="del-confirm" v-model="deleteConfirm" type="text" autocomplete="off" />

        <button
          class="btn btn-danger"
          style="margin-top: 1rem; border: 1px solid #ef4444;"
          :disabled="deleteBusy || deleteConfirm !== me.username"
          @click="submitDelete"
        >
          {{ deleteBusy ? 'Deleting…' : 'Delete my account' }}
        </button>

        <p v-if="deleteErr" class="error" style="margin: 0.75rem 0 0;">{{ deleteErr }}</p>
      </div>

    </template>
  </div>
</template>

<style scoped>
.form-row { margin-bottom: 1rem; }
</style>
