<script setup>
import { ref, onMounted } from 'vue'
import {
  listComments, postComment, deleteComment,
  listRemoteComments, postRemoteComment,
  getSession,
} from '../api'
import Icon from './Icon.vue'

const props = defineProps({
  username: String,
  videoId: Number,
  source: { type: String, default: 'local' },
})

const items = ref([])
const me = ref(null)
const draft = ref('')
const busy = ref(false)
const error = ref(null)

async function load() {
  try {
    const data = props.source === 'remote'
      ? await listRemoteComments(props.videoId)
      : await listComments(props.username, props.videoId)
    const sess = await getSession()
    items.value = data.items || []
    me.value = sess
  } catch (e) {
    error.value = e.message
  }
}

async function submit() {
  const text = draft.value.trim()
  if (!text) return
  busy.value = true
  error.value = null
  try {
    const created = props.source === 'remote'
      ? await postRemoteComment(props.videoId, text)
      : await postComment(props.username, props.videoId, text)
    items.value.push(created)
    draft.value = ''
  } catch (e) {
    error.value = e.message
  } finally {
    busy.value = false
  }
}

async function remove(id) {
  error.value = null
  try {
    await deleteComment(props.username, props.videoId, id)
    items.value = items.value.filter(i => i.id !== id)
  } catch (e) {
    error.value = e.message
  }
}

onMounted(load)
</script>

<template>
  <section style="margin-top: 1.5rem; padding-top: 1.25rem; border-top: 1px solid var(--color-line);">
    <h4 style="margin: 0 0 0.75rem; color: var(--color-ink-muted); font-size: 0.85rem; text-transform: uppercase; letter-spacing: 0.05em;">
      <Icon name="comment" :size="14" style="vertical-align: -2px; margin-right: 0.3rem;" />
      {{ items.length }} Comments
    </h4>

    <div style="display: flex; flex-direction: column; gap: 0.5rem;">
      <div
        v-for="c in items"
        :key="c.id"
        style="padding: 0.75rem 0; border-bottom: 1px solid var(--color-line);"
      >
        <div style="display: flex; align-items: center; justify-content: space-between; gap: 0.5rem;">
          <span style="color: var(--color-brand); font-weight: 600; font-size: 0.9rem;">
            {{ c.username }}
          </span>
          <button
            v-if="me && me.username === c.username && !c.is_remote"
            class="btn btn-ghost btn-danger"
            style="padding: 0.25rem 0.5rem; font-size: 0.75rem;"
            @click="remove(c.id)"
          >
            <Icon name="trash" :size="12" />
          </button>
        </div>
        <p style="margin: 0.25rem 0 0; color: var(--color-ink);">{{ c.body }}</p>
      </div>

      <p v-if="items.length === 0" class="muted" style="margin: 0;">No comments yet.</p>
    </div>

    <form
      v-if="me"
      @submit.prevent="submit"
      style="display: flex; gap: 0.5rem; margin-top: 1rem; align-items: flex-end;"
    >
      <textarea
        v-model="draft"
        maxlength="2000"
        rows="2"
        placeholder="Write a comment…"
        style="flex: 1; min-height: 3rem;"
      ></textarea>
      <button
        type="submit"
        class="btn btn-primary"
        :disabled="busy || !draft.trim()"
        style="flex-shrink: 0;"
      >
        <Icon name="send" :size="18" />
      </button>
    </form>

    <p v-else class="muted" style="margin-top: 1rem;">Log in to comment.</p>

    <p v-if="error" class="error" style="margin-top: 0.5rem;">{{ error }}</p>
  </section>
</template>
