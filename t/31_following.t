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
use Mojo::JSON qw(encode_json decode_json);
use Mojo::Transaction::HTTP;

local $ENV{FEDIVID_DATABASE_URL} =
    'postgresql://postgres:1234pass@127.0.0.1/fedivid_test';
local $ENV{FEDIVID_UPLOAD_DIR} = '/tmp/fedivid-test-uploads';
local $ENV{FEDIVID_ALLOW_INSECURE_FETCH} = 1;
local $ENV{FEDIVID_RATE_LIMIT_DISABLED} = 1;

{
    package RecordingUA;
    use Mojo::Base -strict, -signatures;

    sub new ($class) { bless { sent => [], routes => {} }, $class }

    sub set_route ($self, $url, $code, $body, $ctype = 'application/activity+json') {
        $self->{routes}{$url} = {
            code  => $code,
            body  => $body,
            ctype => $ctype,
        };
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
        my $route = $self->{routes}{$url};
        if ($route) {
            $tx->res->code($route->{code});
            $tx->res->headers->content_type($route->{ctype});
            $tx->res->body($route->{body});
        } else {
            $tx->res->code(404);
            $tx->res->headers->content_type('text/plain');
            $tx->res->body('not found');
        }
        return $tx;
    }

    sub start ($self, $tx) {
        push @{ $self->{sent} }, $tx;
        $tx->res->code(202);
        $tx->res->headers->content_type('application/activity+json');
        $tx->res->body('{"status":"ok"}');
        return $tx;
    }

    sub sent ($self) { @{ $self->{sent} } }
}

package main;

my $t  = Test::Mojo->new('FediVid');
my $pg = setup_test_db($t->app);

local $ENV{FEDIVID_ADMIN_SECRET} = 'test-admin-token';

$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'alice' }, )
  ->status_is(201);

my $alice = $pg->db->query(
    'SELECT private_key_pem, public_key_pem FROM users WHERE username = ?',
    'alice'
)->hash;

my $key_id = 'http://localhost:3000/users/alice#main-key';

my $remote_rsa  = Crypt::OpenSSL::RSA->generate_key(2048);
my $remote_pub  = $remote_rsa->get_public_key_x509_string();
my $remote_priv = $remote_rsa->get_private_key_string();

my $actor_url    = 'https://remote.test/users/bob';
my $remote_key   = 'https://remote.test/users/bob#main-key';
my $remote_inbox = 'https://remote.test/users/bob/inbox';

my $remote_actor_json = encode_json({
    id    => $actor_url,
    type  => 'Person',
    inbox => $remote_inbox,
    publicKey => {
        id           => $remote_key,
        owner        => $actor_url,
        publicKeyPem => $remote_pub,
    },
});

my $ua = RecordingUA->new;
$ua->set_route($actor_url, 200, $remote_actor_json);
$t->app->ua($ua);

sub signed_post_json {
    my ($path, $payload, $key_override) = @_;
    my $body = encode_json($payload);
    my $tx   = $t->ua->build_tx(POST => $path);
    $tx->req->headers->content_type('application/activity+json');
    $tx->req->body($body);
    sign_request(
        $tx->req,
        $key_override // $key_id,
        $alice->{private_key_pem},
    );
    $t->ua->start($tx);
    return $tx;
}

# --- Unsigned → 401 ---
$t->post_ok('/api/users/alice/following', json => { actor => $actor_url })
  ->status_is(401)
  ->json_is('/error', 'unauthorized');

# --- Cannot follow self ---
{
    my $tx = signed_post_json('/api/users/alice/following', {
        actor => 'http://localhost:3000/users/alice',
    });
    is $tx->res->code, 400, 'cannot follow self';
    is $tx->res->json->{error}, 'cannot_follow_self', 'correct error';
}

# --- Missing actor field ---
{
    my $tx = signed_post_json('/api/users/alice/following', {});
    is $tx->res->code, 400, 'missing actor rejected';
    is $tx->res->json->{error}, 'missing_actor', 'correct error';
}

# --- Successful follow ---
{
    my $before = $pg->db->query(
        'SELECT COUNT(*) AS n FROM deliveries WHERE username = ?', 'alice'
    )->hash->{n};

    my $tx = signed_post_json('/api/users/alice/following', {
        actor => $actor_url,
    });
    is $tx->res->code, 202, 'follow accepted';

    my $row = $pg->db->query(
        'SELECT * FROM following WHERE local_user = ? AND remote_actor = ?',
        'alice', $actor_url
    )->hash;
    ok $row, 'following row exists';
    ok !$row->{accepted}, 'not accepted yet';
    is $row->{remote_inbox}, $remote_inbox, 'inbox stored';

    my $delivery = $pg->db->query(
        'SELECT * FROM deliveries WHERE username = ? ORDER BY id DESC LIMIT 1',
        'alice'
    )->hash;
    ok $delivery, 'delivery queued';
    is $delivery->{inbox_url}, $remote_inbox, 'delivery targets remote inbox';
    my $follow = decode_json($delivery->{activity});
    is $follow->{type},   'Follow', 'queued activity is Follow';
    is $follow->{actor},  'http://localhost:3000/users/alice', 'actor is local user';
    is $follow->{object}, $actor_url, 'object is remote actor';

    my $after = $pg->db->query(
        'SELECT COUNT(*) AS n FROM deliveries WHERE username = ?', 'alice'
    )->hash->{n};
    is $after, $before + 1, 'one new delivery queued';
}

# --- Duplicate follow → 409 ---
{
    my $tx = signed_post_json('/api/users/alice/following', {
        actor => $actor_url,
    });
    is $tx->res->code, 409, 'duplicate follow rejected';
    is $tx->res->json->{error}, 'already_following', 'correct error';
}

# --- Index lists the following ---
$t->get_ok('/api/users/alice/following')
  ->status_is(200)
  ->json_is('/totalItems', 1)
  ->json_is('/items/0/remote_actor', $actor_url)
  ->json_is('/items/0/accepted', 0);

# --- Receive Accept ---
{
    my $row = $pg->db->query(
        'SELECT activity_id FROM following WHERE local_user = ? AND remote_actor = ?',
        'alice', $actor_url
    )->hash;

    my $accept = encode_json({
        '@context' => 'https://www.w3.org/ns/activitystreams',
        id         => 'https://remote.test/accepts/1',
        type       => 'Accept',
        actor      => $actor_url,
        object     => {
            id     => $row->{activity_id},
            type   => 'Follow',
            actor  => 'http://localhost:3000/users/alice',
            object => $actor_url,
        },
    });

    $pg->db->query(
        'INSERT INTO remote_actors (url, actor, public_key, fetched_at)
              VALUES (?, ?, ?, NOW())
         ON CONFLICT (url) DO UPDATE SET fetched_at = NOW()',
        $actor_url, $remote_actor_json, $remote_pub
    );

    my $tx = $t->ua->build_tx(POST => '/users/alice/inbox');
    $tx->req->headers->content_type('application/activity+json');
    $tx->req->body($accept);
    sign_request($tx->req, $remote_key, $remote_priv);
    $t->ua->start($tx);
    is $tx->res->code, 202, 'Accept accepted';

    my $after = $pg->db->query(
        'SELECT accepted FROM following WHERE local_user = ? AND remote_actor = ?',
        'alice', $actor_url
    )->hash;
    ok $after->{accepted}, 'following marked accepted';
}

done_testing();
