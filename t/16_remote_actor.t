use Mojo::Base -strict, -signatures;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use FediVid::RemoteActor;
use Mojo::Transaction::HTTP;

local $ENV{FEDIVID_ALLOW_INSECURE_FETCH} = 1;

package MockUA {
    use Mojo::Base -strict, -signatures;

    sub new ($class, %routes) {
        bless { routes => \%routes, hits => {} }, $class;
    }

    sub get ($self, $url, @rest) {
        $self->{hits}{$url}++;

        my $tx = Mojo::Transaction::HTTP->new;
        $tx->req->method('GET');
        $tx->req->url->parse($url);

        my $handler = $self->{routes}{$url};
        if (!$handler) {
            $tx->res->code(404);
            $tx->res->headers->content_type('text/plain');
            $tx->res->body('not found');
        } else {
            my ($code, $ctype, $body) = $handler->();
            $tx->res->code($code);
            $tx->res->headers->content_type($ctype);
            $tx->res->body($body);
        }

        return $tx;
    }

    sub hits ($self, $url) { $self->{hits}{$url} // 0 }
}

package main;

use Test::Mojo;
use Mojo::JSON qw(encode_json);
use lib "$FindBin::Bin/lib";
use TestDB qw(setup_test_db);
use FediVid;

local $ENV{FEDIVID_DATABASE_URL} =
    'postgresql://postgres:1234pass@127.0.0.1/fedivid_test';

my $t  = Test::Mojo->new('FediVid');
my $pg = setup_test_db($t->app);

my $bob_actor = <<'JSON';
{
    "@context": "https://www.w3.org/ns/activitystreams",
    "id": "http://127.0.0.1:9999/users/bob",
    "type": "Person",
    "publicKey": {
        "id": "http://127.0.0.1:9999/users/bob#main-key",
        "owner": "http://127.0.0.1:9999/users/bob",
        "publicKeyPem": "-----BEGIN PUBLIC KEY-----\nFAKE\n-----END PUBLIC KEY-----\n"
    }
}
JSON

my $nokey_actor = '{"id":"http://127.0.0.1:9999/users/nokey","type":"Person"}';

my $ua = MockUA->new(
    'http://127.0.0.1:9999/users/bob'    => sub { (200, 'application/activity+json', $bob_actor) },
    'http://127.0.0.1:9999/users/nokey'  => sub { (200, 'application/activity+json', $nokey_actor) },
    'http://127.0.0.1:9999/users/broken' => sub { (200, 'text/plain', 'not json') },
);

# --- Happy path ---
{
    my ($actor, $err) = FediVid::RemoteActor::fetch(
        $ua, $pg->db, 'http://127.0.0.1:9999/users/bob#main-key'
    );
    ok $actor, 'fetched actor' or diag "error: $err";
    is $actor->{type}, 'Person', 'actor type is Person';
    is $actor->{publicKey}{publicKeyPem},
        "-----BEGIN PUBLIC KEY-----\nFAKE\n-----END PUBLIC KEY-----\n",
        'public key PEM extracted';
    is $ua->hits('http://127.0.0.1:9999/users/bob'), 1, 'one HTTP hit';
}

# --- Cache hit ---
{
    my ($actor, $err) = FediVid::RemoteActor::fetch(
        $ua, $pg->db, 'http://127.0.0.1:9999/users/bob#main-key'
    );
    ok $actor, 'second fetch returns actor from cache';
    is $ua->hits('http://127.0.0.1:9999/users/bob'), 1, 'no additional HTTP hit';
}

# --- Missing publicKey ---
{
    my ($actor, $err) = FediVid::RemoteActor::fetch(
        $ua, $pg->db, 'http://127.0.0.1:9999/users/nokey#main-key'
    );
    ok !$actor, 'fails when actor has no publicKey';
    like $err, qr/publicKey/, 'error mentions publicKey';
}

# --- Non-JSON ---
{
    my ($actor, $err) = FediVid::RemoteActor::fetch(
        $ua, $pg->db, 'http://127.0.0.1:9999/users/broken#main-key'
    );
    ok !$actor, 'fails on non-JSON response';
}

# --- 404 ---
{
    my ($actor, $err) = FediVid::RemoteActor::fetch(
        $ua, $pg->db, 'http://127.0.0.1:9999/users/missing#main-key'
    );
    ok !$actor, 'fails on 404';
    like $err, qr/404/, 'error mentions 404';
}

# --- Expiry ---
{
    $pg->db->query(
        q{UPDATE remote_actors SET fetched_at = NOW() - INTERVAL '25 hours'
           WHERE url = ?},
        'http://127.0.0.1:9999/users/bob'
    );
    my ($actor, $err) = FediVid::RemoteActor::fetch(
        $ua, $pg->db, 'http://127.0.0.1:9999/users/bob#main-key'
    );
    ok $actor, 'expired entry refetched';
    is $ua->hits('http://127.0.0.1:9999/users/bob'), 2, 'HTTP hit again';
}

# --- URL guard active when insecure fetch disabled ---
{
    local $ENV{FEDIVID_ALLOW_INSECURE_FETCH} = 0;
    my ($actor, $err) = FediVid::RemoteActor::fetch(
        $ua, $pg->db, 'https://127.0.0.1/users/bob#main-key'
    );
    ok !$actor, 'private IP rejected';
    like $err, qr/URL rejected/, 'error mentions URL';
}

done_testing();
