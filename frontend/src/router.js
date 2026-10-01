import { createRouter, createWebHistory } from 'vue-router'
import Timeline from './views/Timeline.vue'
import Local from './views/Local.vue'
import Federated from './views/Federated.vue'
import Explore from './views/Explore.vue'
import UserVideos from './views/UserVideos.vue'
import Login from './views/Login.vue'
import Upload from './views/Upload.vue'
import Search from './views/Search.vue'
import Notifications from './views/Notifications.vue'
import Messages from './views/Messages.vue'
import Thread from './views/Thread.vue'
import Settings from './views/Settings.vue'
import VideoDetail from './views/VideoDetail.vue'
import Signup from './views/Signup.vue'
import NewMessage from './views/NewMessage.vue'
import Admin from './views/Admin.vue'
import Following from './views/Following.vue'
import Followers from './views/Followers.vue'
import RemoteVideoDetail from './views/RemoteVideoDetail.vue'
import RemoteActor from './views/RemoteActor.vue'
import About from './views/About.vue'

const routes = [
  { path: '/', name: 'home', component: Timeline },
  { path: '/timeline', redirect: '/' },
  { path: '/local', name: 'local', component: Local },
  { path: '/federated', name: 'federated', component: Federated },
  { path: '/explore', name: 'explore', component: Explore },
  { path: '/search', name: 'search', component: Search },
  { path: '/u/:username/v/:id', name: 'video', component: VideoDetail },
  { path: '/users/:username', name: 'user', component: UserVideos, props: true },
  { path: '/login', name: 'login', component: Login },
  { path: '/upload', name: 'upload', component: Upload },
  { path: '/notifications', name: 'notifications', component: Notifications },
  { path: '/messages', name: 'messages', component: Messages },
  { path: '/messages/thread/:username', name: 'thread', component: Thread },
  { path: '/settings', name: 'settings', component: Settings },
  { path: '/signup', name: 'signup', component: Signup },
  { path: '/messages/new', name: 'new-message', component: NewMessage },
  { path: '/admin', name: 'admin', component: Admin },
  { path: '/following', name: 'following', component: Following },
  { path: '/users/:username/followers', name: 'followers', component: Followers },
  { path: '/v/:id', name: 'remote-video', component: RemoteVideoDetail },
  { path: '/remote/:handle', name: 'remote-actor', component: RemoteActor },
  { path: '/about', name: 'about', component: About },
]

export default createRouter({
  history: createWebHistory(),
  routes,
})
