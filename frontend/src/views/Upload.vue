<script setup>
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import { getSession, uploadVideo } from '../api'
import Icon from '../components/Icon.vue'

const router = useRouter()
const username = ref('')
const title = ref('')
const description = ref('')
const file = ref(null)
const busy = ref(false)
const error = ref(null)
const tagsInput = ref('')

async function init() {
  const sess = await getSession()
  if (!sess) { router.push('/login'); return }
  username.value = sess.username
}
init()

function pick(e) { file.value = e.target.files[0] || null }

async function submit() {
  error.value = null
  if (!file.value) { error.value = 'Pick a file'; return }
  if (!title.value.trim()) { error.value = 'Title is required'; return }
  const tags = tagsInput.value
    .split(',')
    .map(t => t.trim())
    .filter(t => t.length > 0)

  busy.value = true
  try {
    await uploadVideo(username.value, {
      title: title.value.trim(),
      description: description.value.trim(),
      tags,
      file: file.value,
    })
    router.push(`/users/${username.value}`)
  } catch (e) {
    error.value = e.message
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div style="max-width: 34rem; margin: 0 auto;" class="stack">
    <div>
      <h1>Upload a video</h1>
      <p class="muted">Your video is transcoded to HLS automatically.</p>
    </div>

    <p v-if="!username" class="loading">Checking session…</p>

    <form
      v-else
      @submit.prevent="submit"
      class="card"
      style="display: flex; flex-direction: column; gap: 1.25rem;"
    >
      <div>
        <label class="label-text" for="up-title">Title</label>
        <input id="up-title" v-model="title" required maxlength="200" placeholder="My first video" />
      </div>

      <div>
        <label class="label-text" for="up-desc">Description</label>
        <textarea id="up-desc" v-model="description" rows="3" maxlength="1000" placeholder="What's this video about?"></textarea>
      </div>

      <div>
        <label class="label-text" for="up-tags">Tags</label>
        <input
          id="up-tags"
          v-model="tagsInput"
          type="text"
          placeholder="music, live, guitar"
        />
        <p class="muted" style="font-size: 0.78rem; margin: 0.4rem 0 0;">
          Comma-separated. Lowercase, digits, dash, underscore.
        </p>
      </div>

      <div>
        <label class="label-text" for="up-file">Video file</label>
        <input id="up-file" type="file" accept="video/*" @change="pick" required />
      </div>

      <button
        type="submit"
        class="btn btn-primary"
        :disabled="busy"
        style="width: 100%; padding: 0.75rem;"
      >
        <Icon name="upload" :size="18" />
        {{ busy ? 'Uploading…' : 'Upload' }}
      </button>

      <p v-if="error" class="error" style="text-align: center; margin: 0;">{{ error }}</p>
    </form>
  </div>
</template>
