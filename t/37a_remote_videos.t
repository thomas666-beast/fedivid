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
local $ENV{FEDIVID_DISABLE_DELIVERY} = 1;
local $ENV{FEDIVID_RATE_LIMIT_DISABLED} = 1;

my $t  = Test::Mojo->new('FediVid');
my $pg = setup_test_db($t->app);

local $ENV{FEDIVID_ADMIN_SECRET} = 'test-admin-token';

$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'alice' }, )
  ->status_is(201);

my $remote_rsa  = Crypt::OpenSSL::RSA->generate_key(2048);
my $remote_priv = $remote_rsa->get_private_key_string();
my $remote_pub  = $remote_rsa->get_public_key_x509_string();
my $key_id      = 'https://remote.test/users/bob#main-key';
my $actor_url   = 'https://remote.test/users/bob';

# Bob's actor
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

# Alice follows Bob (accepted)
$pg->db->query(
    'INSERT INTO followers (local_user, remote_actor, remote_inbox, accepted)
          VALUES (?, ?, ?, TRUE)',
    'alice', $actor_url, 'https://remote.test/users/bob/inbox'
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

# --- Remote Create / Video gets stored ---
{
    my $tx = signed_post('/users/alice/inbox', {
        '@context' => 'https://www.w3.org/ns/activitystreams',
        id         => 'https://remote.test/activities/1',
        type       => 'Create',
        actor      => $actor_url,
        published  => '2026-09-27T20:00:00Z',
        object     => {
            id           => 'https://remote.test/videos/cat.mp4',
            type         => 'Video',
            name         => 'A cat',
            summary      => 'Very cute',
            url          => 'https://remote.test/videos/cat.mp4',
            mediaType    => 'video/mp4',
            duration     => 12,
            width        => 1280,
            height       => 720,
            attributedTo => $actor_url,
        },
    });
    is $tx->res->code, 202, 'Create accepted';

    my $row = $pg->db->query(
        'SELECT * FROM remote_videos WHERE local_user = ? AND object_id = ?',
        'alice', 'https://remote.test/videos/cat.mp4'
    )->hash;
    ok $row, 'remote video row exists';
    is $row->{remote_actor}, $actor_url, 'remote_actor stored';
    is $row->{title},        'A cat',    'title stored';
    is $row->{description},  'Very cute', 'description stored';
    is $row->{duration} + 0, 12,  'duration stored';
    is $row->{width}  + 0, 1280, 'width stored';
    is $row->{height} + 0, 720,  'height stored';
}

# --- Duplicate Create is idempotent ---
{
    signed_post('/users/alice/inbox', {
        type   => 'Create',
        actor  => $actor_url,
        object => {
            id   => 'https://remote.test/videos/cat.mp4',
            type => 'Video',
            name => 'A cat',
        },
    });

    my $count = $pg->db->query(
        'SELECT COUNT(*) AS n FROM remote_videos WHERE local_user = ? AND object_id = ?',
        'alice', 'https://remote.test/videos/cat.mp4'
    )->hash->{n};
    is $count, 1, 'still one row';
}

# --- Create with non-Video object is ignored ---
{
    signed_post('/users/alice/inbox', {
        type   => 'Create',
        actor  => $actor_url,
        object => {
            id   => 'https://remote.test/posts/1',
            type => 'Note',
            content => 'Hello',
        },
    });

    my $count = $pg->db->query(
        'SELECT COUNT(*) AS n FROM remote_videos WHERE local_user = ?',
        'alice'
    )->hash->{n};
    is $count, 1, 'no new row for Note';
}

# --- Create from non-followed actor is not stored ---
{
    my $stranger_rsa  = Crypt::OpenSSL::RSA->generate_key(2048);
    my $stranger_priv = $stranger_rsa->get_private_key_string();
    my $stranger_pub  = $stranger_rsa->get_public_key_x509_string();
    my $stranger_url  = 'https://remote.test/users/charlie';
    my $stranger_key  = 'https://remote.test/users/charlie#main-key';

    $pg->db->query(
        'INSERT INTO remote_actors (url, actor, public_key, fetched_at)
              VALUES (?, ?, ?, NOW())',
        $stranger_url,
        encode_json({
            id    => $stranger_url,
            type  => 'Person',
            inbox => 'https://remote.test/users/charlie/inbox',
            publicKey => {
                id           => $stranger_key,
                owner        => $stranger_url,
                publicKeyPem => $stranger_pub,
            },
        }),
        $stranger_pub,
    );

    my $body = encode_json({
        type   => 'Create',
        actor  => $stranger_url,
        object => {
            id   => 'https://remote.test/videos/dog.mp4',
            type => 'Video',
            name => 'A dog',
        },
    });
    my $tx = $t->ua->build_tx(POST => '/users/alice/inbox');
    $tx->req->headers->content_type('application/activity+json');
    $tx->req->body($body);
    sign_request($tx->req, $stranger_key, $stranger_priv);
    $t->ua->start($tx);
    is $tx->res->code, 202, 'stranger Create accepted';

    my $count = $pg->db->query(
        'SELECT COUNT(*) AS n FROM remote_videos WHERE local_user = ?',
        'alice'
    )->hash->{n};
    is $count, 1, 'no row for non-followed actor';
}

done_testing();
