use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use TestDB qw(setup_test_db);
use FediVid;
use FediVid::Password qw(hash_password);
use Mojo::JSON qw(encode_json);

local $ENV{FEDIVID_DATABASE_URL} =
    'postgresql://postgres:1234pass@127.0.0.1/fedivid_test';
local $ENV{FEDIVID_RATE_LIMIT_DISABLED} = 1;

my $t  = Test::Mojo->new('FediVid');
my $pg = setup_test_db($t->app);

$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'alice' },
)->status_is(201);

$pg->db->query(
    'UPDATE users SET password_hash = ? WHERE username = ?',
    hash_password('devpass123'), 'alice'
);

# Insert a local video
$pg->db->query(
    "INSERT INTO videos
         (username, title, content_type, file_path, size_bytes,
          activity_id, transcode_status, duration_seconds, width, height,
          published_at)
     VALUES (?, 'Local video', 'video/mp4', '/tmp/x.mp4', 100, ?, 'ready', 5, 640, 480,
             NOW() - INTERVAL '1 hour')",
    'alice',
    'http://localhost:3000/users/alice/videos/abc.mp4'
);

# Alice follows bob (remote) — required for his videos to appear in her timeline
$pg->db->query(
    "INSERT INTO following (local_user, remote_actor, accepted)
     VALUES ('alice', 'https://remote.test/users/bob', TRUE)"
);

# Insert a remote video from bob
$pg->db->query(
    "INSERT INTO remote_videos
         (local_user, remote_actor, object_id, title, description,
          video_url, media_type, duration, width, height, published_at)
     VALUES (?, 'https://remote.test/users/bob', ?, ?, 'From bob',
             ?, 'video/mp4', 8, 1280, 720, NOW())",
    'alice',
    'https://remote.test/videos/xyz.mp4',
    'Remote video',
    'https://remote.test/videos/xyz.mp4'
);

# --- Unauthenticated -> 401 ---
$t->get_ok('/api/users/alice/timeline')
  ->status_is(401)
  ->json_is('/error', 'unauthorized');

# --- Log in and fetch ---
$t->post_ok('/api/sessions', json => {
    username => 'alice', password => 'devpass123'
})->status_is(200);

$t->get_ok('/api/users/alice/timeline')
  ->status_is(200)
  ->json_is('/totalItems', 2);

# Remote video should be first (newer)
$t->json_is('/items/0/source', 'remote')
  ->json_is('/items/0/title',  'Remote video')
  ->json_is('/items/0/url',    'https://remote.test/videos/xyz.mp4');

$t->json_is('/items/1/source', 'local')
  ->json_is('/items/1/title',  'Local video');

# Local video has an hls_url
$t->json_like('/items/1/hls_url', qr{/hls/master\.m3u8$});

# --- Unknown user -> 404 ---
$t->get_ok('/api/users/nobody/timeline')->status_is(404);

done_testing();
