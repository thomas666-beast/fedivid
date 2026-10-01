<script setup>
import { ref, onMounted, onBeforeUnmount, watch } from 'vue'
import Hls from 'hls.js'

const props = defineProps({
  hlsSrc:   { type: String, default: null },
  fallback: { type: String, default: null },
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

  const source = props.hlsSrc || props.fallback
  if (!source) return

  if (props.hlsSrc && Hls.isSupported()) {
    hls = new Hls({ enableWorker: true })
    hls.loadSource(props.hlsSrc)
    hls.attachMedia(el)
  } else if (props.hlsSrc && el.canPlayType('application/vnd.apple.mpegurl')) {
    el.src = props.hlsSrc
  } else {
    el.src = source
  }
}

onMounted(load)
watch(() => [props.hlsSrc, props.fallback], load)
onBeforeUnmount(destroyHls)
</script>

<template>
  <video ref="videoEl" controls preload="metadata" class="video-player" />
</template>

<style scoped>
.video-player {
    width: 100%;
    background: #000;
    border-radius: 14px;
    aspect-ratio: 16 / 9;
    display: block;
}
</style>
