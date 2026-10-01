use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use TestDB qw(setup_test_db);
use FediVid;
use FediVid::Signature qw(sign_request);
use Crypt::OpenSSL::RSA;
use Mojo::JSON qw(encode_json);

local $ENV{FEDIVID_DATABASE_URL} =
    'postgresql://postgres:1234pass@127.0.0.1/fedivid_test';
local $ENV{FEDIVID_UPLOAD_DIR} = '/tmp/fedivid-test-uploads';
local $ENV{FEDIVID_DISABLE_DELIVERY} = 1;
local $ENV{FEDIVID_RATE_LIMIT_DISABLED} = 1;

my $t  = Test::Mojo->new('FediVid');
my $pg = setup_test_db($t->app);

local $ENV{FEDIVID_ADMIN_SECRET} = 'test-admin-token';

$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'alice' }, )
  ->status_is(201);

$pg->db->query(
    "INSERT INTO videos (username, title, content_type, file_path, size_bytes,
                         activity_id, transcode_status, duration_seconds,
                         width, height)
     VALUES (?, ?, ?, ?, ?, ?, 'ready', 1.0, 320, 240)",
    'alice', 'Test video', 'video/mp4', '/tmp/test.mp4', 100,
    'http://localhost:3000/users/alice/videos/abc.mp4'
);
my $video_id = $pg->db->query(
    "SELECT id FROM videos WHERE username = 'alice'"
)->hash->{id};

# Fake outbound UA to skip Accept sending
{
    package FakeUA;
    use Mojo::Base -strict, -signatures;
    sub new ($class) { bless {}, $class }
    sub build_tx ($self, $method, $url) {
        my $tx = Mojo::Transaction::HTTP->new;
        $tx->req->method($method);
        $tx->req->url->parse($url);
        return $tx;
    }
    sub start ($self, $tx) {
        $tx->res->code(202);
        $tx->res->headers->content_type('application/activity+json');
        $tx->res->body('{"status":"ok"}');
        return $tx;
    }
}

package main;
$t->app->ua(FakeUA->new);

# Remote actor setup
my $remote_rsa  = Crypt::OpenSSL::RSA->generate_key(2048);
my $remote_priv = $remote_rsa->get_private_key_string();
my $remote_pub  = $remote_rsa->get_public_key_x509_string();
my $key_id      = 'https://remote.test/users/bob#main-key';
my $actor_url   = 'https://remote.test/users/bob';

$pg->db->query(
    'INSERT INTO remote_actors (url, actor, public_key, fetched_at)
          VALUES (?, ?, ?, NOW())',
    $actor_url,
    encode_json({
        id    => $actor_url,
        type  => 'Person',
        inbox => 'https://remote.test/users/bob/inbox',
        publicKey => {
            id           => $key_id,
            owner        => $actor_url,
            publicKeyPem => $remote_pub,
        },
    }),
    $remote_pub,
);

sub signed_post {
    my ($path, $payload) = @_;
    my $body = encode_json($payload);
    my $tx   = $t->ua->build_tx(POST => $path);
    $tx->req->headers->content_type('application/activity+json');
    $tx->req->body($body);
    sign_request($tx->req, $key_id, $remote_priv);
    $t->ua->start($tx);
    return $tx;
}

# --- Like a video ---
{
    my $tx = signed_post('/users/alice/inbox', {
        '@context' => 'https://www.w3.org/ns/activitystreams',
        id         => 'https://remote.test/likes/1',
        type       => 'Like',
        actor      => $actor_url,
        object     => 'http://localhost:3000/users/alice/videos/abc.mp4',
    });
    is $tx->res->code, 202, 'Like accepted';

    my $row = $pg->db->query(
        'SELECT * FROM likes WHERE video_id = ? AND remote_actor = ?',
        $video_id, $actor_url
    )->hash;
    ok $row, 'like row created';
    is $row->{activity_id}, 'https://remote.test/likes/1', 'activity_id stored';
}

# --- Duplicate Like is idempotent ---
{
    my $tx = signed_post('/users/alice/inbox', {
        type   => 'Like',
        id     => 'https://remote.test/likes/1-dup',
        actor  => $actor_url,
        object => 'http://localhost:3000/users/alice/videos/abc.mp4',
    });
    is $tx->res->code, 202, 'duplicate Like accepted';

    my $count = $pg->db->query(
        'SELECT COUNT(*) AS n FROM likes WHERE video_id = ? AND remote_actor = ?',
        $video_id, $actor_url
    )->hash->{n};
    is $count, 1, 'still one like row';
}

# --- Like a nonexistent video is silently accepted ---
{
    my $tx = signed_post('/users/alice/inbox', {
        type   => 'Like',
        id     => 'https://remote.test/likes/2',
        actor  => $actor_url,
        object => 'http://localhost:3000/users/alice/videos/nonexistent.mp4',
    });
    is $tx->res->code, 202, 'Like for unknown video accepted';

    my $count = $pg->db->query(
        'SELECT COUNT(*) AS n FROM likes WHERE video_id = ?',
        $video_id
    )->hash->{n};
    is $count, 1, 'no extra like row';
}

# --- Undo Like ---
{
    my $tx = signed_post('/users/alice/inbox', {
        type   => 'Undo',
        id     => 'https://remote.test/undos/1',
        actor  => $actor_url,
        object => {
            type   => 'Like',
            actor  => $actor_url,
            object => 'http://localhost:3000/users/alice/videos/abc.mp4',
        },
    });
    is $tx->res->code, 202, 'Undo Like accepted';

    my $row = $pg->db->query(
        'SELECT * FROM likes WHERE video_id = ? AND remote_actor = ?',
        $video_id, $actor_url
    )->hash;
    ok !$row, 'like row removed';
}

done_testing();
