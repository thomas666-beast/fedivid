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
use Mojo::Transaction::HTTP;

local $ENV{FEDIVID_DATABASE_URL} =
    'postgresql://postgres:1234pass@127.0.0.1/fedivid_test';
local $ENV{FEDIVID_RATE_LIMIT_DISABLED} = 1;
local $ENV{FEDIVID_ALLOW_INSECURE_FETCH} = 1;

{
    package RecordingUA;
    use Mojo::Base -strict, -signatures;
    sub new ($class) { bless { routes => {} }, $class }
    sub set_route ($self, $url, $body, $ctype = 'application/activity+json') {
        $self->{routes}{$url} = { body => $body, ctype => $ctype };
    }
    sub build_tx ($self, $method, $url) {
        my $tx = Mojo::Transaction::HTTP->new;
        $tx->req->method($method);
        $tx->req->url->parse($url);
        return $tx;
    }
    sub get ($self, $url, @rest) {
        my $tx = Mojo::Transaction::HTTP->new;
        $tx->req->method('GET');
        $tx->req->url->parse($url);
        my $r = $self->{routes}{$url};
        if ($r) {
            $tx->res->code(200);
            $tx->res->headers->content_type($r->{ctype});
            $tx->res->body($r->{body});
        } else {
            $tx->res->code(404);
            $tx->res->headers->content_type('text/plain');
            $tx->res->body('not found');
        }
        return $tx;
    }
    sub start ($self, $tx) {
        $tx->res->code(202);
        $tx->res->headers->content_type('application/json');
        $tx->res->body('{"status":"ok"}');
        return $tx;
    }
}

package main;

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

# Alice has a local video
$pg->db->query(
    "INSERT INTO videos
         (username, title, content_type, file_path, size_bytes,
          activity_id, transcode_status, duration_seconds, width, height)
     VALUES (?, 'Local video', 'video/mp4', '/tmp/x.mp4', 100,
             'http://localhost:3000/users/alice/videos/abc.mp4',
             'ready', 5, 640, 480)",
    'alice'
);
my $video_id = $pg->db->query(
    "SELECT id FROM videos WHERE username = 'alice'"
)->hash->{id};

# --- Local comment still works ---
$t->post_ok("/api/users/alice/videos/$video_id/comments", json => {
    body => 'local comment',
})->status_is(201)->json_is('/is_remote', 0);

$t->get_ok("/api/users/alice/videos/$video_id/comments")
  ->status_is(200)
  ->json_is('/totalItems', 1);

# --- Inbound remote comment ---
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

my $tx = $t->ua->build_tx(POST => '/users/alice/inbox');
$tx->req->headers->content_type('application/activity+json');
$tx->req->body(encode_json({
    '@context' => 'https://www.w3.org/ns/activitystreams',
    id         => 'https://remote.test/activities/1',
    type       => 'Create',
    actor      => $actor_url,
    object     => {
        id           => 'https://remote.test/notes/1',
        type         => 'Note',
        attributedTo => $actor_url,
        inReplyTo    => 'http://localhost:3000/users/alice/videos/abc.mp4',
        content      => 'nice video!',
    },
}));
sign_request($tx->req, $remote_key, $remote_priv);
$t->ua->start($tx);
is $tx->res->code, 202, 'remote comment accepted';

$t->get_ok("/api/users/alice/videos/$video_id/comments")
  ->status_is(200)
  ->json_is('/totalItems', 2)
  ->json_is('/items/1/body', 'nice video!')
  ->json_is('/items/1/is_remote', 1);
like $t->tx->res->json->{items}[1]{username}, qr/remote\.test/, 'shows remote author';

# --- Duplicate is idempotent ---
{
    my $tx = $t->ua->build_tx(POST => '/users/alice/inbox');
    $tx->req->headers->content_type('application/activity+json');
    $tx->req->body(encode_json({
        type   => 'Create',
        actor  => $actor_url,
        object => {
            id           => 'https://remote.test/notes/1',
            type         => 'Note',
            attributedTo => $actor_url,
            inReplyTo    => 'http://localhost:3000/users/alice/videos/abc.mp4',
            content      => 'nice video!',
        },
    }));
    sign_request($tx->req, $remote_key, $remote_priv);
    $t->ua->start($tx);

    $t->get_ok("/api/users/alice/videos/$video_id/comments")
      ->json_is('/totalItems', 2);
}

# --- Outbound comment on a remote video ---
{
    $pg->db->query(
        "INSERT INTO remote_videos
             (local_user, remote_actor, object_id, title, video_url, published_at)
         VALUES (?, ?, ?, ?, ?, NOW())",
        'alice', $actor_url,
        'https://remote.test/users/bob/videos/xyz.mp4',
        'Remote video',
        'https://remote.test/users/bob/videos/xyz.mp4',
    );

    $pg->db->query(
        "INSERT INTO videos
             (username, title, content_type, file_path, size_bytes,
              activity_id, transcode_status, duration_seconds, width, height)
         VALUES (?, 'Stub remote video', 'video/mp4', '/tmp/y.mp4', 100,
                 'https://remote.test/users/bob/videos/xyz.mp4',
                 'ready', 5, 640, 480)",
        'alice'
    );
    my $stub_id = $pg->db->query(
        "SELECT id FROM videos WHERE title = 'Stub remote video'"
    )->hash->{id};

    my $remote_actor_json = encode_json({
        id    => $actor_url,
        type  => 'Person',
        inbox => 'https://remote.test/users/bob/inbox',
        publicKey => {
            id           => $remote_key,
            owner        => $actor_url,
            publicKeyPem => $remote_pub,
        },
    });

    my $ua = RecordingUA->new;
    $ua->set_route($actor_url, $remote_actor_json);
    $t->app->ua($ua);

    $t->post_ok("/api/users/alice/videos/$stub_id/comments", json => {
        body => 'from alice to the remote',
    })->status_is(201);

    my $delivery = $pg->db->query(
        "SELECT * FROM deliveries WHERE username = 'alice' ORDER BY id DESC LIMIT 1"
    )->hash;
    ok $delivery, 'delivery queued';
    is $delivery->{inbox_url}, 'https://remote.test/users/bob/inbox', 'inbox correct';

    my $activity = decode_json($delivery->{activity});
    is $activity->{type}, 'Create', 'activity is Create';
    is $activity->{object}{type}, 'Note', 'object is Note';
    is $activity->{object}{inReplyTo}, 'https://remote.test/users/bob/videos/xyz.mp4',
        'inReplyTo points at the remote video';
}

done_testing();
