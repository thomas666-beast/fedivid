use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use TestDB qw(setup_test_db);
use FediVid;

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

# Seed a video
$pg->db->query(
    "INSERT INTO videos
         (username, title, content_type, file_path, size_bytes,
          activity_id, transcode_status, duration_seconds, width, height)
     VALUES
         ('alice', 'v1', 'video/mp4', '/tmp/a.mp4', 100,
          'http://localhost:3000/users/alice/videos/a.mp4', 'ready', 5, 640, 480)"
);

# --- Users list requires admin ---
$t->get_ok('/api/admin/users')
  ->status_is(403);

$t->get_ok('/api/admin/users',
    { 'X-Admin-Token' => 'test-admin-token' })
  ->status_is(200)
  ->json_is('/totalItems', 2)
  ->json_is('/items/0/username', 'alice')
  ->json_is('/items/0/video_count', 1)
  ->json_is('/items/1/username', 'bob')
  ->json_is('/items/1/video_count', 0);

# --- Health requires admin ---
$t->get_ok('/api/admin/health')
  ->status_is(403);

$t->get_ok('/api/admin/health',
    { 'X-Admin-Token' => 'test-admin-token' })
  ->status_is(200)
  ->json_is('/deliveries/pending', 0)
  ->json_is('/deliveries/succeeded', 0)
  ->json_is('/deliveries/failed', 0)
  ->json_is('/videos/transcode_pending', 0)
  ->json_is('/videos/transcode_failed', 0)
  ->json_is('/remote_actors', 0);

# --- Seeded failures show up in health aggregate ---
{
    $pg->db->query(
        "INSERT INTO deliveries
             (username, inbox_url, activity, activity_id, attempts, last_error, completed_at)
         VALUES
             ('alice', 'https://x/inbox', '{}'::jsonb, 'a1', 3, 'connection refused', NOW()),
             ('alice', 'https://y/inbox', '{}'::jsonb, 'a2', 0, NULL, NULL)"
    );

    $t->get_ok('/api/admin/health',
        { 'X-Admin-Token' => 'test-admin-token' })
      ->status_is(200)
      ->json_is('/deliveries/pending', 1)
      ->json_is('/deliveries/failed', 1)
      ->json_is('/deliveries/max_attempts', 3);
}

# --- Failures endpoint requires admin ---
$t->get_ok('/api/admin/failures')
  ->status_is(403);

# --- Failures endpoint returns grouped rows ---
{
    $t->get_ok('/api/admin/failures',
        { 'X-Admin-Token' => 'test-admin-token' })
      ->status_is(200)
      ->json_is('/totalItems', 1)
      ->json_is('/items/0/inbox_url', 'https://x/inbox')
      ->json_is('/items/0/last_error', 'connection refused')
      ->json_is('/items/0/count', 1)
      ->json_is('/items/0/max_attempts', 3);
}

# --- Multiple rows in the same group collapse ---
{
    $pg->db->query(
        "INSERT INTO deliveries
             (username, inbox_url, activity, activity_id, attempts, last_error, completed_at)
         VALUES
             ('alice', 'https://x/inbox', '{}'::jsonb, 'a3', 5, 'connection refused', NOW())"
    );

    $t->get_ok('/api/admin/failures',
        { 'X-Admin-Token' => 'test-admin-token' })
      ->status_is(200)
      ->json_is('/totalItems', 1)
      ->json_is('/items/0/count', 2);
}

# --- Search filters ---
{
    $t->get_ok('/api/admin/failures?search=nomatch',
        { 'X-Admin-Token' => 'test-admin-token' })
      ->status_is(200)
      ->json_is('/totalItems', 0)
      ->json_is('/items', []);

    $t->get_ok('/api/admin/failures?search=x/inbox',
        { 'X-Admin-Token' => 'test-admin-token' })
      ->status_is(200)
      ->json_is('/totalItems', 1);

    $t->get_ok('/api/admin/failures?search=refused',
        { 'X-Admin-Token' => 'test-admin-token' })
      ->status_is(200)
      ->json_is('/totalItems', 1);
}

# --- Failure rows endpoint ---
{
    $t->get_ok('/api/admin/failure-rows?inbox_url=https%3A%2F%2Fx%2Finbox&last_error=connection%20refused',
        { 'X-Admin-Token' => 'test-admin-token' })
      ->status_is(200)
      ->json_has('/items')
      ->json_is('/items/0/attempts', 5);  # newest first
}

# --- Delete user ---
$t->delete_ok('/api/admin/users/bob',
    { 'X-Admin-Token' => 'test-admin-token' })
  ->status_is(200)
  ->json_is('/username', 'bob');

$t->get_ok('/api/admin/users',
    { 'X-Admin-Token' => 'test-admin-token' })
  ->json_is('/totalItems', 1)
  ->json_is('/items/0/username', 'alice');

# --- Delete unknown user → 404 ---
$t->delete_ok('/api/admin/users/nobody',
    { 'X-Admin-Token' => 'test-admin-token' })
  ->status_is(404);

# --- Delete requires admin ---
$t->delete_ok('/api/admin/users/alice')
  ->status_is(403);

done_testing();
