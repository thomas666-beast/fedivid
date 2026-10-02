<script setup>
import { ref, computed } from 'vue'
import { useRouter } from 'vue-router'
import { getSession, uploadVideoWithProgress } from '../api'
import Icon from '../components/Icon.vue'

const router = useRouter()
const username = ref('')
const title = ref('')
const description = ref('')
const file = ref(null)
const busy = ref(false)
const error = ref(null)
const tagsInput = ref('')

// Matches the backend's max_request_size (500 MiB)
const MAX_FILE_BYTES = 500 * 1024 * 1024

// Upload progress
const progress = ref(0)      // 0..100
const uploadedBytes = ref(0)
const totalBytes = ref(0)

const fileLabel = computed(() => {
  if (!file.value) return null
  const mb = (file.value.size / (1024 * 1024)).toFixed(1)
  return `${file.value.name} (${mb} MB)`
})

async function init() {
  const sess = await getSession()
  if (!sess) { router.push('/login'); return }
  username.value = sess.username
}
init()

function pick(e) {
  error.value = null
  const f = e.target.files[0] || null
  if (f && f.size > MAX_FILE_BYTES) {
    error.value = `File is too large. Maximum upload size is 500 MB.`
    e.target.value = ''
    file.value = null
    return
  }
  file.value = f
}

function fmtBytes(n) {
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`
  if (n < 1024 * 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)} MB`
  return `${(n / (1024 * 1024 * 1024)).toFixed(2)} GB`
}

async function submit() {
  error.value = null
  if (!file.value) { error.value = 'Pick a file'; return }
  if (!title.value.trim()) { error.value = 'Title is required'; return }

  const tags = tagsInput.value
    .split(',')
    .map(t => t.trim())
    .filter(t => t.length > 0)

  busy.value = true
  progress.value = 0
  uploadedBytes.value = 0
  totalBytes.value = file.value.size

  try {
    await uploadVideoWithProgress(username.value, {
      title: title.value.trim(),
      description: description.value.trim(),
      tags,
      file: file.value,
    }, (p) => {
      progress.value = p.percent
      uploadedBytes.value = p.loaded
      totalBytes.value = p.total
    })

    router.push(`/users/${username.value}`)
  } catch (e) {
    error.value = e.detail || e.message
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
        <p v-if="fileLabel" class="muted" style="font-size: 0.78rem; margin: 0.4rem 0 0;">
          {{ fileLabel }}
        </p>
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

      <!-- Upload progress -->
      <div v-if="busy && totalBytes > 0" class="progress-wrap">
        <div class="progress-bar">
          <div class="progress-fill" :style="{ width: progress + '%' }"></div>
        </div>
        <p class="muted" style="font-size: 0.78rem; margin: 0.35rem 0 0; text-align: center;">
          {{ fmtBytes(uploadedBytes) }} / {{ fmtBytes(totalBytes) }} — {{ Math.round(progress) }}%
        </p>
      </div>

      <p v-if="error" class="error" style="text-align: center; margin: 0;">{{ error }}</p>
    </form>
  </div>
</template>

<style scoped>
.progress-wrap {
    margin-top: 0.25rem;
}
.progress-bar {
    width: 100%;
    height: 8px;
    background: #232833;
    border-radius: 9999px;
    overflow: hidden;
}
html:not(.dark) .progress-bar { background: #e7e7ec; }
.progress-fill {
    height: 100%;
    background: linear-gradient(90deg, #8b5cf6, #d946ef);
    border-radius: 9999px;
    transition: width 0.15s linear;
}
</style>
