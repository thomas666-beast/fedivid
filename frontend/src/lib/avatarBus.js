import { reactive } from 'vue'

export const avatarState = reactive({
  username: null,   // which user's avatar just changed
  version: 0,       // monotonically increasing
})

export function bumpAvatarVersion(username) {
  avatarState.username = username
  avatarState.version += 1
}
