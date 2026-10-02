-- 1 up
CREATE TABLE users (
    id         SERIAL PRIMARY KEY,
    username   TEXT NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 1 down
DROP TABLE users;

-- 2 up
CREATE TABLE activities (
    id           SERIAL PRIMARY KEY,
    username     TEXT NOT NULL REFERENCES users(username) ON DELETE CASCADE,
    activity     JSONB NOT NULL,
    received_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX activities_username_received_idx
    ON activities (username, received_at DESC);

-- 2 down
DROP TABLE activities;

-- 3 up
ALTER TABLE users
    ADD COLUMN private_key_pem TEXT,
    ADD COLUMN public_key_pem  TEXT;

-- 3 down
ALTER TABLE users
    DROP COLUMN private_key_pem,
    DROP COLUMN public_key_pem;

-- 4 up
CREATE TABLE remote_actors (
    url          TEXT PRIMARY KEY,
    actor        JSONB NOT NULL,
    public_key   TEXT NOT NULL,
    fetched_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX remote_actors_fetched_idx ON remote_actors (fetched_at);

-- 4 down
DROP TABLE remote_actors;


-- 5 up
CREATE TABLE followers (
    id            SERIAL PRIMARY KEY,
    local_user    TEXT NOT NULL REFERENCES users(username) ON DELETE CASCADE,
    remote_actor  TEXT NOT NULL,
    remote_inbox  TEXT,
    accepted      BOOLEAN NOT NULL DEFAULT FALSE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (local_user, remote_actor)
);

CREATE INDEX followers_local_user_idx ON followers (local_user);

-- 5 down
DROP TABLE followers;


-- 6 up
CREATE TABLE outbox_activities (
    id           BIGSERIAL PRIMARY KEY,
    username     TEXT NOT NULL REFERENCES users(username) ON DELETE CASCADE,
    activity     JSONB NOT NULL,
    activity_id  TEXT NOT NULL,
    published_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX outbox_activities_user_time_idx
    ON outbox_activities (username, published_at DESC);

CREATE UNIQUE INDEX outbox_activities_activity_id_idx
    ON outbox_activities (activity_id);

-- 6 down
DROP TABLE outbox_activities;


-- 7 up
CREATE TABLE videos (
    id           BIGSERIAL PRIMARY KEY,
    username     TEXT NOT NULL REFERENCES users(username) ON DELETE CASCADE,
    title        TEXT NOT NULL,
    description  TEXT,
    content_type TEXT NOT NULL,
    file_path    TEXT NOT NULL,
    size_bytes   BIGINT NOT NULL,
    activity_id  TEXT NOT NULL UNIQUE,
    published_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX videos_user_time_idx ON videos (username, published_at DESC);

-- 7 down
DROP TABLE videos;

-- 8 up
ALTER TABLE videos
    ADD COLUMN duration_seconds NUMERIC(10,3),
    ADD COLUMN width            INT,
    ADD COLUMN height           INT;

-- 8 down
ALTER TABLE videos
    DROP COLUMN duration_seconds,
    DROP COLUMN width,
    DROP COLUMN height;


-- 9 up
ALTER TABLE videos
    ADD COLUMN transcode_status TEXT NOT NULL DEFAULT 'pending',
    ADD COLUMN hls_dir          TEXT;

CREATE INDEX videos_transcode_status_idx ON videos (transcode_status)
    WHERE transcode_status = 'pending';

-- 9 down
DROP INDEX videos_transcode_status_idx;
ALTER TABLE videos
    DROP COLUMN transcode_status,
    DROP COLUMN hls_dir;

-- 10 up
CREATE TABLE likes (
    id           SERIAL PRIMARY KEY,
    video_id     BIGINT NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
    remote_actor TEXT NOT NULL,
    activity_id  TEXT NOT NULL UNIQUE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (video_id, remote_actor)
);

CREATE INDEX likes_video_idx ON likes (video_id);
CREATE INDEX likes_actor_idx ON likes (remote_actor);

-- 10 down
DROP TABLE likes;

-- 11 up
CREATE TABLE following (
    id           SERIAL PRIMARY KEY,
    local_user   TEXT NOT NULL REFERENCES users(username) ON DELETE CASCADE,
    remote_actor TEXT NOT NULL,
    remote_inbox TEXT,
    activity_id  TEXT,
    accepted     BOOLEAN NOT NULL DEFAULT FALSE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (local_user, remote_actor)
);

CREATE INDEX following_local_user_idx ON following (local_user);

-- 11 down
DROP TABLE following;


-- 12 up
CREATE TABLE deliveries (
    id           BIGSERIAL PRIMARY KEY,
    username     TEXT NOT NULL REFERENCES users(username) ON DELETE CASCADE,
    inbox_url    TEXT NOT NULL,
    activity     JSONB NOT NULL,
    activity_id  TEXT NOT NULL,
    attempts     INT NOT NULL DEFAULT 0,
    last_error   TEXT,
    scheduled_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX deliveries_pending_idx
    ON deliveries (scheduled_at)
    WHERE completed_at IS NULL;

-- 12 down
DROP TABLE deliveries;

-- 13 up
ALTER TABLE users ADD COLUMN password_hash TEXT;

-- 13 down
ALTER TABLE users DROP COLUMN password_hash;

-- 14 up
CREATE TABLE remote_videos (
    id            BIGSERIAL PRIMARY KEY,
    local_user    TEXT NOT NULL REFERENCES users(username) ON DELETE CASCADE,
    remote_actor  TEXT NOT NULL,
    object_id     TEXT NOT NULL,
    title         TEXT,
    description   TEXT,
    video_url     TEXT,
    media_type    TEXT,
    duration      INT,
    width         INT,
    height        INT,
    published_at  TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (local_user, object_id)
);

CREATE INDEX remote_videos_user_published_idx
    ON remote_videos (local_user, published_at DESC);

-- 14 down
DROP TABLE remote_videos;

-- 15 up
CREATE TABLE notifications (
    id          BIGSERIAL PRIMARY KEY,
    username    TEXT NOT NULL REFERENCES users(username) ON DELETE CASCADE,
    type        TEXT NOT NULL,
    actor       TEXT NOT NULL,
    object_id   TEXT,
    object_url  TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    seen_at     TIMESTAMPTZ
);

CREATE INDEX notifications_user_created_idx
    ON notifications (username, created_at DESC);

CREATE INDEX notifications_user_unseen_idx
    ON notifications (username)
    WHERE seen_at IS NULL;

-- 15 down
DROP TABLE notifications;

-- 16 up
CREATE TABLE rate_limits (
    key          TEXT PRIMARY KEY,
    window_start TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    count        INT NOT NULL DEFAULT 1
);

CREATE INDEX rate_limits_window_idx ON rate_limits (window_start);

-- 16 down
DROP TABLE rate_limits;

-- 17 up
CREATE TABLE comments (
    id         BIGSERIAL PRIMARY KEY,
    video_id   BIGINT NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
    username   TEXT NOT NULL REFERENCES users(username) ON DELETE CASCADE,
    body       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX comments_video_created_idx
    ON comments (video_id, created_at);

-- 17 down
DROP TABLE comments;

-- 18 up
CREATE TABLE messages (
    id         BIGSERIAL PRIMARY KEY,
    sender     TEXT NOT NULL REFERENCES users(username) ON DELETE CASCADE,
    recipient  TEXT NOT NULL REFERENCES users(username) ON DELETE CASCADE,
    body       TEXT NOT NULL,
    read_at    TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX messages_recipient_created_idx
    ON messages (recipient, created_at DESC);

CREATE INDEX messages_thread_idx
    ON messages (sender, recipient, created_at);

-- 18 down
DROP TABLE messages;

-- 19 up
DROP TABLE IF EXISTS messages;

CREATE TABLE messages (
    id              BIGSERIAL PRIMARY KEY,
    sender_actor    TEXT NOT NULL,
    recipient_actor TEXT NOT NULL,
    body            TEXT NOT NULL,
    activity_id     TEXT,
    is_remote       BOOLEAN NOT NULL DEFAULT FALSE,
    read_at         TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX messages_recipient_created_idx
    ON messages (recipient_actor, created_at DESC);

CREATE INDEX messages_thread_idx
    ON messages (sender_actor, recipient_actor, created_at);

CREATE UNIQUE INDEX messages_activity_id_idx
    ON messages (activity_id);

-- 19 down
DROP TABLE messages;


-- 20 up
DROP TABLE IF EXISTS comments;

CREATE TABLE comments (
    id                BIGSERIAL PRIMARY KEY,
    video_id          BIGINT REFERENCES videos(id) ON DELETE CASCADE,
    video_actor       TEXT NOT NULL,
    author_actor      TEXT NOT NULL,
    body              TEXT NOT NULL,
    activity_id       TEXT,
    is_remote         BOOLEAN NOT NULL DEFAULT FALSE,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX comments_video_created_idx
    ON comments (video_actor, created_at);

CREATE UNIQUE INDEX comments_activity_id_idx
    ON comments (activity_id);

-- 20 down
DROP TABLE comments;

CREATE TABLE comments (
    id         BIGSERIAL PRIMARY KEY,
    video_id   BIGINT NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
    username   TEXT NOT NULL REFERENCES users(username) ON DELETE CASCADE,
    body       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- 21 up
CREATE TABLE announces (
    id              BIGSERIAL PRIMARY KEY,
    username        TEXT NOT NULL REFERENCES users(username) ON DELETE CASCADE,
    actor           TEXT NOT NULL,
    object_url      TEXT NOT NULL,
    activity_id     TEXT,
    is_remote       BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX announces_user_created_idx
    ON announces (username, created_at DESC);

CREATE UNIQUE INDEX announces_activity_id_idx
    ON announces (activity_id);

CREATE UNIQUE INDEX announces_local_unique_idx
    ON announces (username, object_url) WHERE is_remote = FALSE;

-- 21 down
DROP TABLE announces;

-- 22 up
CREATE TABLE worker_heartbeats (
    name       TEXT PRIMARY KEY,
    last_seen  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    processed  BIGINT NOT NULL DEFAULT 0
);

-- 22 down
DROP TABLE worker_heartbeats;

-- 23 up
ALTER TABLE notifications ADD COLUMN video_id BIGINT;

-- 23 down
ALTER TABLE notifications DROP COLUMN video_id;


-- 24 up
ALTER TABLE remote_videos ADD COLUMN poster_path TEXT;

-- 24 down
ALTER TABLE remote_videos DROP COLUMN poster_path;

-- 25 up
ALTER TABLE remote_videos ADD COLUMN poster_url TEXT;

-- 25 down
ALTER TABLE remote_videos DROP COLUMN poster_url;


-- 26 up
ALTER TABLE users ADD COLUMN avatar_path TEXT;

-- 26 down
ALTER TABLE users DROP COLUMN avatar_path;

-- 27 up
ALTER TABLE users ADD COLUMN disabled_at TIMESTAMPTZ;

-- 27 down
ALTER TABLE users DROP COLUMN disabled_at;


-- 28 up
CREATE OR REPLACE FUNCTION notify_new_message() RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify('messages', json_build_object(
        'id',         NEW.id,
        'sender',     NEW.sender_actor,
        'recipient',  NEW.recipient_actor,
        'body',       NEW.body,
        'created_at', NEW.created_at
    )::text);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER messages_notify
    AFTER INSERT ON messages
    FOR EACH ROW EXECUTE FUNCTION notify_new_message();

-- 28 down
DROP TRIGGER messages_notify ON messages;
DROP FUNCTION notify_new_message();


-- 29 up
ALTER TABLE messages
    ADD COLUMN hidden_by_sender    BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN hidden_by_recipient BOOLEAN NOT NULL DEFAULT FALSE;

-- 29 down
ALTER TABLE messages
    DROP COLUMN hidden_by_sender,
    DROP COLUMN hidden_by_recipient;


-- 30 up
ALTER TABLE videos ADD COLUMN tags TEXT[] NOT NULL DEFAULT '{}';
ALTER TABLE remote_videos ADD COLUMN tags TEXT[] NOT NULL DEFAULT '{}';
CREATE INDEX videos_tags_idx ON videos USING GIN (tags);
CREATE INDEX remote_videos_tags_idx ON remote_videos USING GIN (tags);

-- 30 down
DROP INDEX videos_tags_idx;
DROP INDEX remote_videos_tags_idx;
ALTER TABLE videos DROP COLUMN tags;
ALTER TABLE remote_videos DROP COLUMN tags;

-- 31 up
ALTER TABLE videos ADD COLUMN transcode_started_at TIMESTAMPTZ;

-- 31 down
ALTER TABLE videos DROP COLUMN transcode_started_at;

-- 32 up
CREATE INDEX deliveries_failed_recent_idx
    ON deliveries (scheduled_at DESC)
    WHERE last_error IS NOT NULL;

-- 32 down
DROP INDEX deliveries_failed_recent_idx;
