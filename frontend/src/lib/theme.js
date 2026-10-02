import { ref, watch } from 'vue'

// Single source of truth for the theme. Defaults to 'dark'.
// Values are only ever 'dark' or 'light'.
function initialTheme() {
  const saved = localStorage.getItem('theme')
  return saved === 'light' ? 'light' : 'dark'
}

export const isDark = ref(initialTheme() === 'dark')

// Apply the class to <html> whenever the theme changes.
function apply(dark) {
  document.documentElement.classList.toggle('dark', dark)
}

// Apply once at import time so the first paint matches.
apply(isDark.value)

// Persist and re-apply on change.
watch(isDark, (v) => {
  apply(v)
  localStorage.setItem('theme', v ? 'dark' : 'light')
})

export function toggleTheme() {
  isDark.value = !isDark.value
}
