use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use TestDB qw(setup_test_db);
use FediVid;
use FediVid::Password qw(hash_password);
use Mojo::JSON qw(encode_json decode_json);
use Mojo::Transaction::HTTP;
use Crypt::OpenSSL::RSA;

local $ENV{FEDIVID_DATABASE_URL} =
    'postgresql://postgres:1234pass@127.0.0.1/fedivid_test';
local $ENV{FEDIVID_RATE_LIMIT_DISABLED} = 1;
local $ENV{FEDIVID_ALLOW_INSECURE_FETCH} = 1;

# --- Recording UA: captures outbound, serves WebFinger and Actor ---
{
    package RecordingUA;
    use Mojo::Base -strict, -signatures;

    sub new ($class) { bless { sent => [], routes => {} }, $class }

    sub set_route ($self, $url, $code, $body, $ctype = 'application/json') {
        $self->{routes}{$url} = { code => $code, body => $body, ctype => $ctype };
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

$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'alice' },
)->status_is(201);

$pg->db->query(
    'UPDATE users SET password_hash = ? WHERE username = ?',
    hash_password('alicepass1'), 'alice'
);

# Remote actor setup
my $remote_pub = Crypt::OpenSSL::RSA->generate_key(2048)->get_public_key_x509_string();
my $actor_url  = 'https://remote.test/users/bob';
my $remote_key = 'https://remote.test/users/bob#main-key';
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

my $webfinger_url = 'https://remote.test/.well-known/webfinger?resource=acct%3Abob%40remote.test';
my $webfinger_json = encode_json({
    subject => 'acct:bob@remote.test',
    links   => [
        { rel => 'self', type => 'application/activity+json', href => $actor_url },
    ],
});

my $ua = RecordingUA->new;
$ua->set_route($actor_url,     200, $remote_actor_json, 'application/activity+json');
$ua->set_route($webfinger_url, 200, $webfinger_json,    'application/jrd+json');
$t->app->ua($ua);

# --- Log in as alice ---
$t->post_ok('/api/sessions', json => {
    username => 'alice', password => 'alicepass1',
})->status_is(200);

# --- Send to remote by handle ---
{
    $t->post_ok('/api/messages', json => {
        from => 'alice',
        to   => '@bob@remote.test',
        body => 'hello from the other server',
    })->status_is(201)
      ->json_is('/sender',    'alice')
      ->json_is('/recipient', 'bob@remote.test')
      ->json_is('/is_remote', 1);

    my $delivery = $pg->db->query(
        "SELECT * FROM deliveries WHERE username = 'alice' ORDER BY id DESC LIMIT 1"
    )->hash;
    ok $delivery, 'delivery row exists';
    is $delivery->{inbox_url}, $remote_inbox, 'delivery targets remote inbox';
    ok !$delivery->{completed_at}, 'delivery is pending';

    my $activity = decode_json($delivery->{activity});
    is $activity->{type}, 'Create', 'activity is Create';
    is $activity->{actor}, 'http://localhost:3000/users/alice', 'actor is alice';
    is $activity->{object}{type}, 'Note', 'object is Note';
    is $activity->{object}{content}, 'hello from the other server', 'content matches';
    is $activity->{object}{to}[0], $actor_url, 'Note addressed to remote actor';
}

# --- Send to remote by URL ---
{
    $t->post_ok('/api/messages', json => {
        from => 'alice',
        to   => $actor_url,
        body => 'by url',
    })->status_is(201)->json_is('/recipient', 'bob@remote.test');
}

# --- Send to local still works ---
{
    $t->post_ok('/api/users',
        { 'X-Admin-Token' => 'test-admin-token' },
        json => { username => 'carol' },
    )->status_is(201);

    $t->post_ok('/api/messages', json => {
        from => 'alice', to => 'carol', body => 'local hi',
    })->status_is(201)
      ->json_is('/recipient', 'carol')
      ->json_is('/is_remote', 0);
}

# --- Unknown handle → 404 ---
{
    my $ua2 = RecordingUA->new;   # no routes
    $t->app->ua($ua2);
    $t->post_ok('/api/messages', json => {
        from => 'alice', to => '@nobody@remote.test', body => 'x',
    })->status_is(404);
}

# --- Malformed recipient → 404 ---
{
    $t->post_ok('/api/messages', json => {
        from => 'alice', to => 'not valid format!', body => 'x',
    })->status_is(404)->json_is('/error', 'recipient_not_found');
}

# --- Cannot message self ---
{
    $t->post_ok('/api/messages', json => {
        from => 'alice', to => 'alice', body => 'hi me',
    })->status_is(400)->json_is('/error', 'cannot_message_self');
}

# --- Wrong user cannot send as alice ---
{
    my $t2 = Test::Mojo->new('FediVid');
    $pg->db->query(
        'UPDATE users SET password_hash = ? WHERE username = ?',
        hash_password('carolpass1'), 'carol'
    );
    $t2->post_ok('/api/sessions', json => {
        username => 'carol', password => 'carolpass1',
    })->status_is(200);

    $t2->post_ok('/api/messages', json => {
        from => 'alice', to => 'carol', body => 'spoof',
    })->status_is(401);
}

done_testing();
