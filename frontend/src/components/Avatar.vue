<script setup>
import { computed } from 'vue'

const props = defineProps({
  username: { type: String, required: true },
  size:     { type: String, default: 'md' },
})

const sizes = { sm: '1.75rem', md: '2.5rem', lg: '4.5rem' }
const fontSizes = { sm: '0.75rem', md: '1rem', lg: '1.75rem' }

const initial = computed(() => {
  const u = (props.username || '').replace(/^@/, '')
  const first = u.split(/[@/]/)[0] || '?'
  return first[0]?.toUpperCase() || '?'
})

const avatarUrl = computed(() => {
  const u = (props.username || '').replace(/^@/, '')
  // Remote actors don't have local avatars yet
  if (u.includes('/users/') || u.includes('@')) return null
  return `/users/${encodeURIComponent(u)}/avatar`
})
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
      background: avatarUrl ? 'transparent' : 'linear-gradient(135deg, #8b5cf6, #d946ef)',
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
      @error="(e) => { e.target.style.display = 'none'; e.target.parentElement.style.background = 'linear-gradient(135deg, #8b5cf6, #d946ef)'; e.target.parentElement.textContent = initial; }"
    />
    <span v-else>{{ initial }}</span>
  </span>
</template>
