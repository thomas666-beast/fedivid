use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use TestDB qw(setup_test_db);
use FediVid;
use FediVid::Password qw(hash_password);

local $ENV{FEDIVID_DATABASE_URL} =
    'postgresql://postgres:1234pass@127.0.0.1/fedivid_test';
local $ENV{FEDIVID_RATE_LIMIT_DISABLED} = 1;

my $t  = Test::Mojo->new('FediVid');
my $pg = setup_test_db($t->app);

$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'alice' },
)->status_is(201);

$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'bob' },
)->status_is(201);

$pg->db->query(
    'UPDATE users SET password_hash = ? WHERE username = ?',
    hash_password('devpass123'), 'alice'
);
$pg->db->query(
    'UPDATE users SET password_hash = ? WHERE username = ?',
    hash_password('bobpass123'), 'bob'
);

# Insert a video for alice
$pg->db->query(
    "INSERT INTO videos
         (username, title, content_type, file_path, size_bytes,
          activity_id, transcode_status, duration_seconds, width, height)
     VALUES (?, 'Test video', 'video/mp4', '/tmp/x.mp4', 100,
             'http://localhost:3000/users/alice/videos/abc.mp4',
             'ready', 5, 640, 480)",
    'alice'
);
my $video_id = $pg->db->query(
    "SELECT id FROM videos WHERE username = 'alice'"
)->hash->{id};

# --- Comments endpoint without auth: list works, empty ---
$t->get_ok("/api/users/alice/videos/$video_id/comments")
  ->status_is(200)
  ->json_is('/totalItems', 0);

# --- Comment without auth -> 401 ---
$t->post_ok("/api/users/alice/videos/$video_id/comments", json => {
    body => 'hello',
})->status_is(401);

# --- Log in as alice, post a comment ---
$t->post_ok('/api/sessions', json => {
    username => 'alice', password => 'devpass123'
})->status_is(200);

my $comment_id;
{
    $t->post_ok("/api/users/alice/videos/$video_id/comments", json => {
        body => 'First comment',
    })->status_is(201)
      ->json_is('/username', 'alice')
      ->json_is('/body', 'First comment');
    $comment_id = $t->tx->res->json->{id};
    ok $comment_id, 'comment id returned';
}

# --- List shows it ---
$t->get_ok("/api/users/alice/videos/$video_id/comments")
  ->status_is(200)
  ->json_is('/totalItems', 1)
  ->json_is('/items/0/body', 'First comment');

# --- Empty body -> 400 ---
$t->post_ok("/api/users/alice/videos/$video_id/comments", json => {
    body => '   ',
})->status_is(400)->json_is('/error', 'empty_body');

# --- Too long -> 400 ---
$t->post_ok("/api/users/alice/videos/$video_id/comments", json => {
    body => 'x' x 2001,
})->status_is(400)->json_is('/error', 'too_long');

# --- Unknown video -> 404 ---
$t->post_ok("/api/users/alice/videos/999999/comments", json => {
    body => 'hello',
})->status_is(404);

# --- Bob cannot delete alice's comment ---
my $t2 = Test::Mojo->new('FediVid');
$t2->post_ok('/api/sessions', json => {
    username => 'bob', password => 'bobpass123'
})->status_is(200);

$t2->delete_ok("/api/users/alice/videos/$video_id/comments/$comment_id")
  ->status_is(403);  # authenticated but not authorized

# --- Alice deletes her own ---
$t->delete_ok("/api/users/alice/videos/$video_id/comments/$comment_id")
  ->status_is(200)
  ->json_is('/ok', 1);

$t->get_ok("/api/users/alice/videos/$video_id/comments")
  ->status_is(200)
  ->json_is('/totalItems', 0);

done_testing();
