import { onBeforeUnmount, onMounted, ref } from 'vue'

export function useInfiniteScroll(loader, options = {}) {
  const sentinel = ref(null)
  const loading = ref(false)
  const done = ref(false)
  const error = ref(null)
  const ready = ref(false)   // ← gate: becomes true after the first manual load
  let observer = null

  async function loadNext() {
    if (loading.value || done.value || error.value || !ready.value) return
    loading.value = true
    try {
      const hasMore = await loader()
      if (hasMore === false) done.value = true
      error.value = null
    } catch (e) {
      error.value = e
      console.error('[infinite-scroll] loader failed:', e)
    } finally {
      loading.value = false
    }
  }

  // Called by the page once the first batch is in state
  function markReady() {
    ready.value = true
    // Re-check after a tick in case the sentinel is already in view
    setTimeout(() => {
      if (sentinel.value) {
        const r = sentinel.value.getBoundingClientRect()
        if (r.top < window.innerHeight + 400) loadNext()
      }
    }, 0)
  }

  // Allow the consumer to clear an error and try again
  function retry() {
    error.value = null
    loadNext()
  }

  onMounted(() => {
    observer = new IntersectionObserver((entries) => {
      if (entries[0].isIntersecting) loadNext()
    }, { rootMargin: '400px' })
    if (sentinel.value) observer.observe(sentinel.value)
  })

  onBeforeUnmount(() => {
    if (observer) observer.disconnect()
  })

  return { sentinel, loading, done, error, loadNext, markReady, retry }
}
