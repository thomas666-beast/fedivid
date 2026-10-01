use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use TestDB qw(setup_test_db);
use FediVid;
use FediVid::Password qw(hash_password);
use FediVid::Signature qw(sign_request);
use Crypt::OpenSSL::RSA;
use Mojo::JSON qw(encode_json decode_json);

local $ENV{FEDIVID_DATABASE_URL} =
    'postgresql://postgres:1234pass@127.0.0.1/fedivid_test';
local $ENV{FEDIVID_RATE_LIMIT_DISABLED} = 1;
local $ENV{FEDIVID_ALLOW_INSECURE_FETCH} = 1;

my $t  = Test::Mojo->new('FediVid');
my $pg = setup_test_db($t->app);

$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'alice' },
)->status_is(201);

$pg->db->query(
    'UPDATE users SET password_hash = ? WHERE username = ?',
    hash_password('alicepass1'), 'alice'
);

$t->post_ok('/api/sessions', json => {
    username => 'alice', password => 'alicepass1',
})->status_is(200);

# Seed a video for alice
$pg->db->query(
    "INSERT INTO videos
         (username, title, description, content_type, file_path, size_bytes,
          activity_id, transcode_status, duration_seconds, width, height)
     VALUES (?, 'Original title', 'Original description', 'video/mp4',
             '/tmp/x.mp4', 100,
             'http://localhost:3000/users/alice/videos/abc.mp4',
             'ready', 5, 640, 480)",
    'alice'
);
my $video_id = $pg->db->query(
    "SELECT id FROM videos WHERE username = 'alice'"
)->hash->{id};

# --- Update title only ---
$t->patch_ok("/api/users/alice/videos/$video_id",
    json => { title => 'New title' },
)->status_is(200)
  ->json_is('/title', 'New title')
  ->json_is('/description', 'Original description')
  ->json_is('/changed', 1);

# --- Update description only ---
$t->patch_ok("/api/users/alice/videos/$video_id",
    json => { description => 'New description' },
)->status_is(200)
  ->json_is('/title', 'New title')
  ->json_is('/description', 'New description');

# --- No-op returns changed: 0 ---
$t->patch_ok("/api/users/alice/videos/$video_id",
    json => { title => 'New title' },
)->status_is(200)->json_is('/changed', 0);

# --- Empty title rejected ---
$t->patch_ok("/api/users/alice/videos/$video_id",
    json => { title => '   ' },
)->status_is(400)->json_is('/error', 'missing_title');

# --- Unknown video → 404 ---
$t->patch_ok("/api/users/alice/videos/99999",
    json => { title => 'x' },
)->status_is(404);

# --- Unauthenticated → 401 ---
{
    my $t2 = Test::Mojo->new('FediVid');
    $t2->patch_ok("/api/users/alice/videos/$video_id",
        json => { title => 'x' },
    )->status_is(401);
}

# --- Inbound Update from remote ---
my $remote_rsa  = Crypt::OpenSSL::RSA->generate_key(2048);
my $remote_priv = $remote_rsa->get_private_key_string();
my $remote_pub  = $remote_rsa->get_public_key_x509_string();
my $actor_url   = 'https://remote.test/users/bob';
my $remote_key  = 'https://remote.test/users/bob#main-key';

$pg->db->query(
    'INSERT INTO remote_actors (url, actor, public_key, fetched_at)
          VALUES (?, ?, ?, NOW())',
    $actor_url,
    encode_json({
        id    => $actor_url,
        type  => 'Person',
        inbox => 'https://remote.test/users/bob/inbox',
        publicKey => {
            id           => $remote_key,
            owner        => $actor_url,
            publicKeyPem => $remote_pub,
        },
    }),
    $remote_pub,
);

# Seed a remote video for alice
$pg->db->query(
    "INSERT INTO remote_videos
         (local_user, remote_actor, object_id, title, description,
          video_url, media_type, published_at)
     VALUES (?, ?, ?, 'Old remote title', 'Old remote description',
             ?, 'video/mp4', NOW())",
    'alice', $actor_url,
    'https://remote.test/videos/xyz.mp4',
    'https://remote.test/videos/xyz.mp4'
);

# Fire an Update
{
    my $tx = $t->ua->build_tx(POST => '/users/alice/inbox');
    $tx->req->headers->content_type('application/activity+json');
    $tx->req->body(encode_json({
        '@context' => 'https://www.w3.org/ns/activitystreams',
        id         => 'https://remote.test/updates/1',
        type       => 'Update',
        actor      => $actor_url,
        object     => {
            id      => 'https://remote.test/videos/xyz.mp4',
            type    => 'Video',
            name    => 'Updated remote title',
            summary => 'Updated remote description',
        },
    }));
    sign_request($tx->req, $remote_key, $remote_priv);
    $t->ua->start($tx);
    is $tx->res->code, 202, 'inbound Update accepted';

    my $row = $pg->db->query(
        'SELECT title, description FROM remote_videos WHERE object_id = ?',
        'https://remote.test/videos/xyz.mp4'
    )->hash;
    is $row->{title}, 'Updated remote title', 'title updated';
    is $row->{description}, 'Updated remote description', 'description updated';
}

done_testing();
