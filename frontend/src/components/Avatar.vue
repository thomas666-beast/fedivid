<script setup>
import { computed, ref, watch } from 'vue'
import { avatarState } from '../lib/avatarBus'

const props = defineProps({
  username: { type: String, required: true },
  size:     { type: String, default: 'md' },
  // Optional explicit image URL. When set, it takes priority over the
  // local /users/:name/avatar path. Used for remote actors whose avatar
  // URL points at another instance.
  src:      { type: String, default: null },
})

const sizes = { sm: '1.75rem', md: '2.5rem', lg: '4.5rem' }
const fontSizes = { sm: '0.75rem', md: '1rem', lg: '1.75rem' }

const failed = ref(false)

watch(() => props.username, () => { failed.value = false })
watch(() => props.src,      () => { failed.value = false })

const initial = computed(() => {
  const u = (props.username || '').replace(/^@/, '')
  const first = u.split(/[@/]/)[0] || '?'
  return first[0]?.toUpperCase() || '?'
})

const avatarUrl = computed(() => {
  if (failed.value) return null

  // Explicit src always wins (used for remote actors).
  if (props.src) return props.src

  const u = (props.username || '').replace(/^@/, '')
  // Local users only. Remote users need the src prop.
  if (u.includes('/users/') || u.includes('@')) return null

  const base = `/users/${encodeURIComponent(u)}/avatar`
  if (avatarState.username === u) {
    return `${base}?v=${avatarState.version}`
  }
  return base
})

const showFallback = computed(() => !avatarUrl.value)

watch(
  () => avatarState.version,
  () => { failed.value = false }
)
</script>

<template>
  <span
    :style="{
      width: sizes[size],
      height: sizes[size],
      fontSize: fontSizes[size],
      display: 'inline-flex',
      alignItems: 'center',
      justifyContent: 'center',
      background: showFallback ? 'linear-gradient(135deg, #8b5cf6, #d946ef)' : 'transparent',
      color: 'white',
      borderRadius: '9999px',
      fontWeight: 700,
      flexShrink: 0,
      userSelect: 'none',
      overflow: 'hidden',
    }"
  >
    <img
      v-if="avatarUrl"
      :src="avatarUrl"
      :alt="username"
      style="width: 100%; height: 100%; object-fit: cover;"
      @error="failed = true"
    />
    <span v-else>{{ initial }}</span>
  </span>
</template>
