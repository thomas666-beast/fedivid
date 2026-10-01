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

$pg->db->query(
    "INSERT INTO videos
         (username, title, description, content_type, file_path, size_bytes,
          activity_id, transcode_status, duration_seconds, width, height)
     VALUES
         ('alice', 'Cooking pasta', 'How to cook pasta', 'video/mp4', '/tmp/a.mp4', 100,
          'http://localhost:3000/users/alice/videos/a.mp4', 'ready', 10, 640, 480),
         ('alice', 'Guitar lesson', 'Beginner guitar', 'video/mp4', '/tmp/b.mp4', 100,
          'http://localhost:3000/users/alice/videos/b.mp4', 'ready', 20, 640, 480),
         ('bob', 'Pasta review', 'Reviewing pasta', 'video/mp4', '/tmp/c.mp4', 100,
          'http://localhost:3000/users/bob/videos/c.mp4', 'ready', 30, 640, 480)"
);

my $alice_video = $pg->db->query(
    "SELECT id FROM videos WHERE title = 'Cooking pasta'"
)->hash->{id};

$pg->db->query(
    "INSERT INTO comments (video_id, video_actor, author_actor, body, is_remote)
     VALUES (?, 'http://localhost:3000/users/alice/videos/a.mp4',
             'http://localhost:3000/users/bob', 'Great pasta recipe!', FALSE)",
    $alice_video
);

# --- Empty query → 400 ---
$t->get_ok('/api/search?q=')
  ->status_is(400)->json_is('/error', 'empty_query');

# --- Too short → 400 ---
$t->get_ok('/api/search?q=a')
  ->status_is(400);

# --- Video search ---
{
    $t->get_ok('/api/search?q=pasta')
      ->status_is(200)
      ->json_is('/query', 'pasta');

    my $titles = [ map { $_->{title} } @{ $t->tx->res->json->{videos} } ];
    is_deeply [ sort @$titles ], ['Cooking pasta', 'Pasta review'],
        'both pasta videos returned';
}

# --- User search ---
$t->get_ok('/api/search?q=alice&type=users')
  ->status_is(200)
  ->json_is('/users/0/username', 'alice')
  ->json_is('/users/0/video_count', 2);

# --- Comment search ---
$t->get_ok('/api/search?q=recipe&type=comments')
  ->status_is(200)
  ->json_is('/comments/0/body', 'Great pasta recipe!');

# --- Type filter excludes others ---
$t->get_ok('/api/search?q=alice&type=videos')
  ->status_is(200)
  ->json_is('/users', [])
  ->json_is('/comments', []);

# --- Case insensitive ---
{
    $t->get_ok('/api/search?q=PASTA&type=videos')
      ->status_is(200);

    my $titles = [ map { $_->{title} } @{ $t->tx->res->json->{videos} } ];
    is scalar(@$titles), 2, 'case-insensitive match returns both';
}

# --- Special chars don't break LIKE ---
$t->get_ok('/api/search?q=%25%25')
  ->status_is(200);

$t->get_ok('/api/search?q=foo_bar')
  ->status_is(200);

done_testing();
