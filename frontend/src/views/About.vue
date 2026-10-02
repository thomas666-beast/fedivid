<script setup>
import { ref, onMounted } from 'vue'
import { getInstanceAbout } from '../api'
import VideoPreviewCard from '../components/VideoPreviewCard.vue'
import Icon from '../components/Icon.vue'
import Avatar from '../components/Avatar.vue'

const info = ref(null)
const loading = ref(true)
const error = ref(null)

onMounted(async () => {
  try {
    info.value = await getInstanceAbout()
  } catch (e) {
    error.value = e.message
  } finally {
    loading.value = false
  }
})
</script>

<template>
  <div class="stack-lg">
    <p v-if="loading" class="loading">Loading…</p>
    <p v-else-if="error" class="error">{{ error }}</p>

    <template v-else-if="info">
      <!-- Hero -->
      <section class="hero">
        <div class="hero-mark">
          <Icon name="play" :size="32" />
        </div>
        <h1 class="hero-name">{{ info.name }}</h1>
        <p v-if="info.description" class="hero-desc">{{ info.description }}</p>

        <div class="hero-stats">
          <div class="hero-stat">
            <div class="hero-stat-value">{{ info.user_count }}</div>
            <div class="hero-stat-label">Users</div>
          </div>
          <div class="hero-stat">
            <div class="hero-stat-value">{{ info.video_count }}</div>
            <div class="hero-stat-label">Videos</div>
          </div>
        </div>

        <div class="hero-actions">
          <RouterLink v-if="info.signup_open" to="/signup" class="btn btn-primary">
            <Icon name="user" :size="16" /> Join this instance
          </RouterLink>
          <RouterLink to="/federated" class="btn">
            <Icon name="repeat" :size="16" /> Browse federation
          </RouterLink>
          <a
            v-if="info.feed_url"
            :href="info.feed_url"
            class="btn rss-btn"
            target="_blank"
            rel="noopener"
            title="Subscribe via RSS"
          >
            <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
              <circle cx="6.18" cy="17.82" r="2.18"/>
              <path d="M4 4.44v2.83c7.03 0 12.73 5.7 12.73 12.73h2.83c0-8.59-6.97-15.56-15.56-15.56zm0 5.66v2.83c3.9 0 7.07 3.17 7.07 7.07h2.83c0-5.47-4.43-9.9-9.9-9.9z"/>
            </svg>
            RSS feed
          </a>
          <a v-if="info.contact" :href="`mailto:${info.contact}`" class="btn">
            <Icon name="send" :size="16" /> Contact
          </a>
        </div>
      </section>

      <!-- Rules -->
      <section v-if="info.rules.length">
        <h2>Rules</h2>
        <ol class="rules">
          <li v-for="(r, i) in info.rules" :key="i">{{ r }}</li>
        </ol>
      </section>

      <!-- Featured videos -->
      <section v-if="info.featured.length">
        <h2>Recent videos</h2>
        <div class="feed">
          <VideoPreviewCard
            v-for="v in info.featured"
            :key="v.id"
            :video="v"
            :username="v.username"
          />
        </div>
      </section>

      <!-- Known instances -->
      <section v-if="info.known_instances.length">
        <h2>Known instances</h2>
        <ul class="known-list">
          <li v-for="(inst, i) in info.known_instances" :key="i">
            <a :href="inst" target="_blank" rel="noopener" class="known-link">
              {{ inst.replace(/^https?:\/\//, '') }}
            </a>
          </li>
        </ul>
      </section>
    </template>
  </div>
</template>

<style scoped>
.stack-lg > * + * { margin-top: 2.5rem; }

.hero {
    display: flex;
    flex-direction: column;
    align-items: center;
    text-align: center;
    gap: 1rem;
    padding: 3rem 2rem;
    background: #14171f;
    border: 1px solid #232833;
    border-radius: 24px;
}
html:not(.dark) .hero { background: #fff; border-color: #e7e7ec; }

.hero-mark {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 64px;
    height: 64px;
    background: linear-gradient(135deg, #8b5cf6, #d946ef);
    color: white;
    border-radius: 18px;
    box-shadow: 0 12px 32px rgba(139, 92, 246, 0.4);
}

.hero-name {
    margin: 0;
    font-size: 2rem;
    font-weight: 800;
    letter-spacing: -0.02em;
}
.hero-desc {
    margin: 0;
    max-width: 32rem;
    color: #a1a7b3;
    font-size: 1rem;
    line-height: 1.6;
}
html:not(.dark) .hero-desc { color: #5a5f6d; }

.hero-stats { display: flex; gap: 3rem; margin-top: 0.5rem; }
.hero-stat { text-align: center; }
.hero-stat-value {
    font-size: 1.75rem;
    font-weight: 800;
    letter-spacing: -0.02em;
    color: #f4f4f7;
}
html:not(.dark) .hero-stat-value { color: #0e0f14; }
.hero-stat-label {
    font-size: 0.72rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: #6a7180;
    margin-top: 0.15rem;
}

.hero-actions {
    display: flex;
    gap: 0.5rem;
    flex-wrap: wrap;
    justify-content: center;
    margin-top: 0.75rem;
}

.rules {
    padding-left: 1.25rem;
    color: #a1a7b3;
    line-height: 1.8;
}
.rules li { padding: 0.25rem 0; }
html:not(.dark) .rules { color: #5a5f6d; }

.known-list { list-style: none; padding: 0; display: flex; flex-direction: column; gap: 0.4rem; }
.known-link {
    color: #8b5cf6;
    font-weight: 600;
    text-decoration: none;
}
.known-link:hover { text-decoration: underline; }

.feed { display: grid; gap: 1.25rem; }
@media (min-width: 640px) {
    .feed { grid-template-columns: 1fr 1fr; }
}
@media (min-width: 900px) {
    .feed { grid-template-columns: 1fr 1fr 1fr; }
}
@media (min-width: 1400px) {
    .feed { grid-template-columns: 1fr 1fr 1fr 1fr; }
}

.rss-btn:hover {
    color: #f59e0b;
    border-color: rgba(245, 158, 11, 0.4);
    background: rgba(245, 158, 11, 0.08);
}
html:not(.dark) .rss-btn:hover {
    color: #d97706;
    border-color: rgba(217, 119, 6, 0.4);
    background: rgba(217, 119, 6, 0.06);
}
</style>
