<script setup>
import { ref, onMounted, onBeforeUnmount, watch } from 'vue'
import Hls from 'hls.js'

const props = defineProps({
  hlsSrc:   { type: String, default: null },
  fallback: { type: String, required: true },
})

const videoEl = ref(null)
let hls = null

function destroyHls() { if (hls) { hls.destroy(); hls = null } }

function load() {
  const el = videoEl.value
  if (!el) return
  destroyHls()
  el.removeAttribute('src')
  el.load()

  if (!props.hlsSrc) { el.src = props.fallback; return }

  if (Hls.isSupported()) {
    hls = new Hls({ enableWorker: true })
    hls.loadSource(props.hlsSrc)
    hls.attachMedia(el)
  } else if (el.canPlayType('application/vnd.apple.mpegurl')) {
    el.src = props.hlsSrc
  } else {
    el.src = props.fallback
  }
}

onMounted(load)
watch(() => [props.hlsSrc, props.fallback], load)
onBeforeUnmount(destroyHls)
</script>

<template>
  <video ref="videoEl" controls preload="metadata"
         class="w-full rounded-xl bg-black aspect-video" />
</template>
